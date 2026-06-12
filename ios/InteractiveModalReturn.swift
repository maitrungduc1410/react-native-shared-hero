import Foundation
import QuartzCore
import UIKit

/// Drives an INTERACTIVE shared-hero return when a `react-native-screens`
/// sheet modal (`presentation: 'modal'` / `'formSheet'`, i.e. a
/// `UISheetPresentationController`) is dismissed by the swipe-down gesture.
///
/// ## Why this exists
///
/// A button dismiss rides the normal registry back-flight: `goBack()` unmounts
/// the modal at the START of the dismiss, so the flight overlaps the slide. A
/// SWIPE dismiss is the opposite — UIKit drives the sheet interactively and RNS
/// only unmounts AFTER the dismiss completes, by which point the list is
/// revealed and any flight is hopelessly late. We can't hook UIKit's
/// interactive sheet transition (RNS owns the presentation controller), so we
/// OBSERVE the sheet's real motion and drive our own overlay copy.
///
/// ## Mechanism (no prediction, always in sync with the real sheet)
///
/// While a sheet-hosted detail hero is on-window a `CADisplayLink` reads its
/// LIVE window position each frame. Capture the resting ("natural") position
/// once the present animation settles, then:
///
///   * `translation = live.minY - natural.minY` is how far the sheet dragged
///     down.
///   * On a downward drag, hide the real hero + list thumbnail and add an
///     overlay snapshot, lerped each frame from `natural + translation` (finger-
///     tracking) toward the list thumbnail as the dismiss progresses.
///   * On release we keep driving the overlay off the sheet's PRESENTATION
///     frame so it stays glued to the real slide, then crossfade to the real
///     list hero (commit) or restore (cancel). The commit/cancel decision is
///     read from where the sheet comes to rest, not from a coordinator flag.
///
/// ## Device-agnostic release detection (the iOS 18 fix)
///
/// We must NOT trust the transition coordinator's interaction-change signal
/// (`isInteractive` / `notifyWhenInteractionChanges`): on iOS 18 + RNS it
/// reports the interactive phase as OVER at the START of a slow drag, so the
/// overlay snaps to the thumbnail immediately. The PHYSICAL finger lift is taken
/// from the sheet's pan gesture recognizer's `.state` where one can be found,
/// with a model-vs-presentation "jump" heuristic as the fallback. Once released
/// we sync to the real slide via the presentation layer (no fixed duration), so
/// neither iOS 18 nor iOS 26 depends on the coordinator.
///
/// ## Known limitation
///
/// The native sheet card still slides as a unit, so the hero is visually
/// "peeled" out of it. Finger-tracking minimises the visible gap but can't
/// eliminate it without owning the sheet's transition controller.
@objc public final class InteractiveModalReturn: NSObject {
  @objc public static let shared = InteractiveModalReturn()
  private override init() { super.init() }

  // MARK: - Tunables.

  /// Frames of <0.5pt position change before the present animation counts as
  /// settled (and we capture the natural resting frame).
  private static let settleStableFrames = 3
  /// Downward drag (pt) that arms the overlay. Small for near-instant tracking,
  /// non-zero so layout jitter can't trip it.
  private static let activateThreshold: CGFloat = 6
  /// Tolerance (pt) between the sheet's live (presentation) and settled (model)
  /// frames that marks the post-release slide as finished.
  private static let settleTolerance: CGFloat = 1.5
  /// Fraction of the dismiss distance the sheet must have travelled, once the
  /// post-release slide settles, to count as a COMMIT rather than a CANCEL.
  private static let commitProgress: CGFloat = 0.5
  /// Model-vs-presentation gap (pt) that flags a release when no sheet pan
  /// recognizer was found: on release the model frame jumps to its final value
  /// while the presentation layer lags.
  private static let releaseJumpThreshold: CGFloat = 60
  /// Ceiling on the post-release follow, so a slide that never reports settled
  /// is still finalised.
  private static let maxReleaseSeconds: CFTimeInterval = 1.0

  // MARK: - Session state.

  private weak var detail: SharedHeroViewImpl?
  private weak var twin: SharedHeroViewImpl?

  private var link: CADisplayLink?
  /// Present animation has settled and `naturalRect` is valid.
  private var ready = false
  /// A downward drag is in progress and the overlay is live.
  private var active = false
  /// Finger released; following the sheet's PRESENTATION frame each tick until
  /// the slide settles, then deciding commit vs cancel from its rest spot.
  private var releasing = false
  /// The terminal crossfade/teardown is running; ignore any stray tick.
  private var finishing = false

  private var overlay: UIView?
  private var hostRetained = false

  private var naturalRect: CGRect = .zero
  private var sourceCorner: CGFloat = 0
  private var destRect: CGRect = .zero
  private var destCorner: CGFloat = 0
  private var dismissRef: CGFloat = 1

  private var lastY: CGFloat = .greatestFiniteMagnitude
  private var stableFrames = 0
  private var releaseDeadline: CFTimeInterval = 0

  // MARK: - Release detection.

  /// The sheet's dismissal pan gesture recognizer, where one can be located.
  /// Captured once the drag is active so we can read the PHYSICAL finger lift
  /// from its `.state` instead of the unreliable transition coordinator. Weak:
  /// it's owned by UIKit's sheet presentation.
  private weak var popRecognizer: UIGestureRecognizer?
  /// Set by `popRecognizer`'s target action the instant it ends/cancels/fails.
  private var recognizerEnded = false
  /// How the current release was detected, for the on-device logs.
  private var releaseBy = ""

  /// The tracked hero has attached to a window at least once. Before that, a
  /// `window == nil` reading just means the modal is still presenting — NOT a
  /// dismiss.
  private var everAttached = false
  /// Deadline for the first attach, so a flight queued for a destination that
  /// never attaches (e.g. aborted) doesn't leave the link spinning forever.
  private var attachDeadline: CFTimeInterval = 0
  private static let maxAttachWaitSeconds: CFTimeInterval = 8

  // MARK: - Arming (called from HeroRegistry.runTwinFlight).

  /// Arm interactive tracking for a freshly-pushed `detail` whose return
  /// destination is `twin` (the list hero). Cheap to call for every twin
  /// flight: if the detail isn't inside a swipe-dismissable sheet (e.g. a plain
  /// native-stack push) we stand down as soon as it settles on-window.
  func arm(detail: SharedHeroViewImpl, twin: SharedHeroViewImpl) {
    // Tear down any previous (un-finalised) session without reversing it.
    disarm()
    self.detail = detail
    self.twin = twin
    self.ready = false
    self.active = false
    self.releasing = false
    self.finishing = false
    self.lastY = .greatestFiniteMagnitude
    self.stableFrames = 0
    self.everAttached = false
    self.attachDeadline = CACurrentMediaTime() + Self.maxAttachWaitSeconds
    startLink()
  }

  // MARK: - Display link.

  private func startLink() {
    stopLink()
    let l = CADisplayLink(target: self, selector: #selector(tick))
    l.add(to: .main, forMode: .common)
    link = l
  }

  private func stopLink() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick() {
    if finishing { return }

    guard let detail = detail else { disarm(); return }

    // Post-release: follow the real slide via the presentation layer.
    if releasing {
      driveRelease(detail: detail)
      return
    }

    // Off-window: before first attach the modal is still presenting — wait,
    // bounded by `attachDeadline`; after having attached, the modal finished
    // dismissing.
    guard detail.contentView.window != nil else {
      if everAttached {
        if active {
          // Very fast swipe that committed before we caught the release edge —
          // follow it straight into the handoff.
          releaseBy = "offwindow"
          beginRelease()
        } else {
          // Non-interactive dismiss (e.g. button) — let the registry's normal
          // back-flight handle it.
          disarm()
        }
      } else if CACurrentMediaTime() > attachDeadline {
        disarm()
      }
      return
    }
    everAttached = true

    let live = detail.windowFrame()
    guard live != .zero else { return }

    if !ready {
      // Sample the natural resting frame once the present animation settles,
      // i.e. once the vertical position stops moving.
      if abs(live.minY - lastY) < 0.5 {
        stableFrames += 1
        if stableFrames >= Self.settleStableFrames {
          if Self.isInSheet(detail.contentView) {
            naturalRect = live
            sourceCorner = detail.effectiveCornerRadius()
            ready = true
          } else {
            // Not a swipe-dismissable sheet (plain push, fullscreen modal, …).
            disarm()
          }
        }
      } else {
        stableFrames = 0
      }
      lastY = live.minY
      return
    }

    // The MODEL frame can jump straight to its final value the instant an
    // interactive dismiss begins (iOS 18 + react-native-screens) — only the
    // PRESENTATION layer follows the finger. Track translation off presentation,
    // falling back to the model frame when nothing is animating yet.
    let presLive = detail.presentationWindowFrame()
    let tracked = presLive != .zero ? presLive : live
    let translation = tracked.minY - naturalRect.minY

    if !active {
      // Once past the threshold, activate and fall through (NO return) to drive
      // the overlay THIS tick — handing off exactly where the sheet already is.
      // Returning would park it at rest for a frame, then jump to the finger
      // (the start-of-drag "snap").
      guard translation > Self.activateThreshold else { return }
      activate()
    }

    // ACTIVE. Latch the sheet's pan recognizer so its `.state` (not the lying
    // coordinator) tells us when the finger lifts; drive the overlay off the
    // finger-following presentation frame until then.
    captureRecognizer()
    if releaseDetected(detail: detail, modelFrame: live) {
      beginRelease()
      driveRelease(detail: detail)
      return
    }

    let p = max(0, min(1, translation / dismissRef))
    logDrag(translation: translation, progress: p)
    driveOverlay(translation: translation, progress: p)
  }

  // MARK: - Release detection helpers.

  private func captureRecognizer() {
    guard popRecognizer == nil, let detail = detail else { return }
    guard let gr = Self.findActiveSheetRecognizer(detail.contentView) else { return }
    popRecognizer = gr
    recognizerEnded = false
    gr.addTarget(self, action: #selector(popRecognizerChanged(_:)))
    heroLog(HeroLog.interactive, "captured recognizer=\(String(describing: type(of: gr))) state=\(gr.state.rawValue)")
  }

  @objc private func popRecognizerChanged(_ gr: UIGestureRecognizer) {
    switch gr.state {
    case .ended, .cancelled, .failed:
      recognizerEnded = true
    default:
      break
    }
  }

  private func releaseRecognizerTarget() {
    popRecognizer?.removeTarget(self, action: #selector(popRecognizerChanged(_:)))
    popRecognizer = nil
    recognizerEnded = false
  }

  /// True once the finger has physically lifted. Primary signal: the sheet pan
  /// recognizer's `.state`. Fallback (none found): the model frame has jumped far
  /// ahead of the presentation layer, which only happens on release.
  private func releaseDetected(detail: SharedHeroViewImpl, modelFrame: CGRect) -> Bool {
    if let gr = popRecognizer {
      if recognizerEnded {
        releaseBy = "gesture"
        return true
      }
      switch gr.state {
      case .ended, .cancelled, .failed:
        releaseBy = "gesture-poll"
        return true
      default:
        return false
      }
    }
    let pres = detail.presentationWindowFrame()
    if pres != .zero, abs(modelFrame.minY - pres.minY) > Self.releaseJumpThreshold {
      releaseBy = "divergence"
      return true
    }
    return false
  }

  // MARK: - Interactive overlay lifecycle.

  private func activate() {
    guard let detail = detail else { return }

    // Capture the source snapshot BEFORE hiding the hero.
    let snap = detail.captureSnapshot()

    // Destination = the list thumbnail, behind the sheet in the same window.
    // iOS recedes/scales the presenter under a pageSheet, so the thumbnail's
    // LIVE `windowFrame()` is transform-distorted; `settledWindowFrame()`
    // (transforms reset) gives its resting position once the presenter scales
    // back to identity on dismiss.
    if let twin = twin, twin.contentView.window != nil {
      let f = twin.settledWindowFrame()
      destRect = f != .zero ? f : naturalRect
      destCorner = twin.effectiveCornerRadius()
    } else {
      destRect = naturalRect
      destCorner = sourceCorner
    }

    let screenH = detail.contentView.window?.bounds.height ?? UIScreen.main.bounds.height
    dismissRef = max(1, screenH - naturalRect.minY)

    let ov = UIView(frame: naturalRect)
    ov.backgroundColor = .clear
    ov.clipsToBounds = true
    ov.layer.cornerRadius = sourceCorner
    ov.layer.masksToBounds = true
    if let img = snap?.image {
      let iv = UIImageView(image: img)
      iv.frame = ov.bounds
      iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      iv.contentMode = .scaleAspectFill
      ov.addSubview(iv)
    }

    let host = OverlayHost.shared.host()
    hostRetained = true
    host.addSubview(ov)
    overlay = ov

    detail.setHiddenForFlight(true)
    twin?.setHiddenForFlight(true)
    // We own this transition now, so the registry's unregister back-flight must
    // stand down (mirrors its `alreadyFlighted` source-flight guard).
    HeroRegistry.shared.markInteractivelyHandled(detail)
    detail.emitTransitionStart()
    active = true
    heroLog(HeroLog.interactive, "activate detail=\(ObjectIdentifier(detail)) natural=\(naturalRect) dest=\(destRect) dismissRef=\(rd(dismissRef))")
  }

  private func driveOverlay(translation: CGFloat, progress p: CGFloat) {
    guard let ov = overlay else { return }
    // Follow the finger early (source offset by the live translation), converge
    // to the thumbnail as the dismiss completes: early on this keeps the overlay
    // over the real (hidden) hero so the empty-card gap is hidden; near the end
    // it peels into the list.
    let followed = naturalRect.offsetBy(dx: 0, dy: translation)
    ov.frame = Self.lerpRect(followed, destRect, p)
    ov.layer.cornerRadius = sourceCorner + (destCorner - sourceCorner) * p
  }

  // MARK: - Post-release follow.

  private func beginRelease() {
    guard !releasing, !finishing else { return }
    releasing = true
    active = false
    releaseDeadline = CACurrentMediaTime() + Self.maxReleaseSeconds
    heroLog(HeroLog.interactive, "release by=\(releaseBy) — following presentation")
  }

  /// Follow the real post-release slide via the presentation layer, then decide
  /// commit vs cancel from where the sheet comes to rest.
  private func driveRelease(detail: SharedHeroViewImpl) {
    guard let ov = overlay else { disarm(); return }

    // Sheet gone → committed; land on the thumbnail and hand off.
    if detail.contentView.window == nil {
      heroLog(HeroLog.interactive, "release: detail off-window → commit")
      finalizeDismiss()
      return
    }

    let pres = detail.presentationWindowFrame()
    let model = detail.windowFrame()
    let frame = pres != .zero ? pres : model
    let translation = frame.minY - naturalRect.minY
    let p = max(0, min(1, translation / dismissRef))
    let followed = naturalRect.offsetBy(dx: 0, dy: translation)
    ov.frame = Self.lerpRect(followed, destRect, p)
    ov.layer.cornerRadius = sourceCorner + (destCorner - sourceCorner) * p

    let settled = pres == .zero
      || (abs(pres.minY - model.minY) < Self.settleTolerance
          && abs(pres.minX - model.minX) < Self.settleTolerance)
    let timedOut = CACurrentMediaTime() > releaseDeadline
    guard settled || timedOut else { return }

    if translation > dismissRef * Self.commitProgress {
      heroLog(HeroLog.interactive, "release settled → commit transl=\(rd(translation)) settled=\(settled) timedOut=\(timedOut)")
      finalizeDismiss()
    } else {
      heroLog(HeroLog.interactive, "release settled → cancel transl=\(rd(translation)) settled=\(settled) timedOut=\(timedOut)")
      finalizeCancel()
    }
  }

  private func finalizeDismiss() {
    guard let ov = overlay else { disarm(); return }
    finishing = true
    let twin = self.twin
    let detail = self.detail
    heroLog(HeroLog.interactive, "finalizeDismiss dest=\(destRect)")
    UIView.animate(
      withDuration: 0.18,
      delay: 0,
      options: [.curveEaseOut],
      animations: {
        ov.frame = self.destRect
        ov.layer.cornerRadius = self.destCorner
      },
      completion: { _ in
        // Reveal the real thumbnail, then fade the overlay out.
        twin?.setHiddenForFlight(false)
        UIView.animate(
          withDuration: 0.12,
          animations: { ov.alpha = 0 },
          completion: { _ in
            ov.removeFromSuperview()
            if self.overlay === ov { self.overlay = nil }
            self.releaseHostIfNeeded()
          }
        )
        detail?.emitTransitionEnd()
      }
    )
    // Drop the link + refs now; the animation closures own the overlay.
    //
    // Deliberately DO NOT `unmarkInteractivelyHandled`: the hero is being torn
    // down and its deferred `commitUnregister` must keep early-returning so it
    // doesn't fire a redundant back-flight. `register` clears the stale mark on
    // remount.
    releaseRecognizerTarget()
    self.detail = nil
    self.twin = nil
    self.active = false
    self.releasing = false
    self.ready = false
    stopLink()
  }

  private func finalizeCancel() {
    guard let detail = detail else { disarm(); return }
    heroLog(HeroLog.interactive, "finalizeCancel")
    // Sheet is back at rest, so the real hero is already at `naturalRect` and
    // the overlay (translation≈0, progress≈0) sits on top — un-hide and remove,
    // no jump.
    detail.setHiddenForFlight(false)
    twin?.setHiddenForFlight(false)
    overlay?.removeFromSuperview()
    overlay = nil
    releaseHostIfNeeded()
    releaseRecognizerTarget()
    HeroRegistry.shared.unmarkInteractivelyHandled(detail)
    detail.emitTransitionEnd()
    active = false
    releasing = false
    // Stay armed + ready so a subsequent drag re-triggers.
  }

  private func releaseHostIfNeeded() {
    if hostRetained {
      OverlayHost.shared.releaseHost()
      hostRetained = false
    }
  }

  /// Tear the session down immediately without reversing or completing a
  /// transition. Used when arming a new session or when the hero is no longer
  /// eligible (deallocated, not a sheet, non-interactive dismiss).
  private func disarm() {
    stopLink()
    if active || releasing {
      detail?.setHiddenForFlight(false)
      twin?.setHiddenForFlight(false)
      detail.map { HeroRegistry.shared.unmarkInteractivelyHandled($0) }
    }
    overlay?.removeFromSuperview()
    overlay = nil
    releaseHostIfNeeded()
    releaseRecognizerTarget()
    detail = nil
    twin = nil
    ready = false
    active = false
    releasing = false
    finishing = false
  }

  // MARK: - Helpers.

  /// Find the pan gesture recognizer driving the sheet's swipe-to-dismiss.
  /// Scans the presented VC's view and its superview chain up to the window for
  /// a recognizer currently tracking (`.began`/`.changed`). Sheets keep their
  /// dismissal pan on an internal container, so this is best-effort — the
  /// model-vs-presentation fallback in `releaseDetected` covers a miss.
  private static func findActiveSheetRecognizer(_ view: UIView) -> UIGestureRecognizer? {
    // Locate the presented sheet's root view.
    var sheetView: UIView?
    var responder: UIResponder? = view
    while let r = responder {
      if let vc = r as? UIViewController, vc.presentingViewController != nil {
        sheetView = vc.view
        break
      }
      responder = r.next
    }

    var candidates: [UIGestureRecognizer] = []
    var v: UIView? = sheetView ?? view
    while let cur = v {
      if let grs = cur.gestureRecognizers { candidates.append(contentsOf: grs) }
      v = cur.superview
    }
    return candidates.first { $0.state == .began || $0.state == .changed }
  }

  /// True if `view` is hosted in a presented sheet (`pageSheet` / `formSheet`),
  /// the only modal styles UIKit lets the user swipe to dismiss. `internal` so
  /// `InteractiveStackPop` can reuse it to exclude sheets from the pop path.
  static func isInSheet(_ view: UIView) -> Bool {
    var responder: UIResponder? = view
    while let r = responder {
      if let vc = r as? UIViewController, vc.presentingViewController != nil {
        if #available(iOS 15.0, *), vc.sheetPresentationController != nil {
          return true
        }
        return vc.modalPresentationStyle == .pageSheet
          || vc.modalPresentationStyle == .formSheet
      }
      responder = r.next
    }
    return false
  }

  private static func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(
      x: a.origin.x + (b.origin.x - a.origin.x) * t,
      y: a.origin.y + (b.origin.y - a.origin.y) * t,
      width: a.size.width + (b.size.width - a.size.width) * t,
      height: a.size.height + (b.size.height - a.size.height) * t
    )
  }

  private func rd(_ v: CGFloat) -> CGFloat { (v * 10).rounded() / 10 }

  // MARK: - Throttled drag logging.

  private var lastLoggedTranslation: CGFloat = .greatestFiniteMagnitude
  private func logDrag(translation: CGFloat, progress p: CGFloat) {
    guard abs(translation - lastLoggedTranslation) >= 24 else { return }
    lastLoggedTranslation = translation
    let grState = popRecognizer?.state.rawValue ?? -1
    heroLog(HeroLog.interactive, "drag transl=\(rd(translation)) p=\(rd(p)) grState=\(grState)")
  }
}
