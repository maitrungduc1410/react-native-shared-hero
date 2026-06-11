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
///     down (works whether UIKit moves it by transform or frame — we only read
///     `windowFrame()`).
///   * On a downward drag, hide the real hero + list thumbnail and add an
///     overlay snapshot, lerped each frame from `natural + translation` (finger-
///     tracking, so it stays over the real hero and covers the empty-card hole)
///     toward the list thumbnail as the dismiss progresses.
///   * Hero leaves the window (committed) ⇒ land on the thumbnail and hand off
///     to the real list hero. Sheet returns to rest (cancelled) ⇒ restore. The
///     commit/cancel decision is UIKit's; we just follow it.
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
  /// Translation at/below which an active drag counts as cancelled (back at rest).
  private static let cancelThreshold: CGFloat = 2

  // MARK: - Session state.

  private weak var detail: SharedHeroViewImpl?
  private weak var twin: SharedHeroViewImpl?

  private var link: CADisplayLink?
  /// Present animation has settled and `naturalRect` is valid.
  private var ready = false
  /// A downward drag is in progress and the overlay is live.
  private var active = false
  /// The synced finish/cancel animation is running; while set the display link
  /// must stand down (the model frame has jumped to its final value).
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

  /// The tracked hero has attached to a window at least once. Before that, a
  /// `window == nil` reading just means the modal is still presenting (content
  /// off-window during the present animation) — NOT a dismiss.
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
    // Synced finish owns everything now; don't let the link fight it (the model
    // frame has jumped to its final value).
    if finishing { return }

    guard let detail = detail else { disarm(); return }

    // Off-window: before first attach the modal is still presenting (content
    // off-window during the present animation) — wait, bounded by
    // `attachDeadline`; after having attached, the modal finished dismissing.
    guard detail.contentView.window != nil else {
      if everAttached {
        if active {
          finalizeDismiss()
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

    let tc = Self.sheetTransitionCoordinator(detail.contentView)

    // RELEASE DETECTION. On finger-lift the dismissal stops being interactive:
    // UIKit snaps the layer's MODEL value to its final state and animates only
    // the presentation layer. `windowFrame()` is model-based, so it has jumped
    // to the end — stop finger-tracking and run the overlay SYNCED to UIKit's
    // completion (same duration + curve) so the hero lands with the sheet
    // sliding off (commit) or returns to rest (cancel) instead of snapping.
    if active, let tc = tc, !tc.isInteractive {
      beginSyncedFinish(
        cancelled: tc.isCancelled,
        duration: tc.transitionDuration,
        curve: tc.completionCurve
      )
      return
    }

    let translation = live.minY - naturalRect.minY

    if !active {
      if translation > Self.activateThreshold {
        activate()
      }
      return
    }

    // FALLBACK cancel detection when there's no coordinator to sync to —
    // just restore at rest. With one, the release branch above handles cancel.
    if tc == nil, translation <= Self.cancelThreshold {
      finalizeCancel()
      return
    }

    let p = max(0, min(1, translation / dismissRef))
    driveOverlay(translation: translation, progress: p)
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
    heroLog(HeroLog.interactive, "activate detail=\(ObjectIdentifier(detail)) natural=\(naturalRect) dest=\(destRect) dismissRef=\(dismissRef)")
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

  private func finalizeDismiss() {
    guard let ov = overlay else { disarm(); return }
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
    self.detail = nil
    self.twin = nil
    self.active = false
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
    HeroRegistry.shared.unmarkInteractivelyHandled(detail)
    detail.emitTransitionEnd()
    active = false
    // Stay armed + ready so a subsequent drag re-triggers.
  }

  /// Animate the overlay in lock-step with UIKit's sheet finish/cancel
  /// completion after release. `duration`/`curve` come from the sheet's
  /// transition coordinator so we match its slide-off (commit) or snap-back
  /// (cancel) instead of snapping.
  private func beginSyncedFinish(
    cancelled: Bool,
    duration: TimeInterval,
    curve: UIView.AnimationCurve
  ) {
    guard let ov = overlay, let detail = detail else { disarm(); return }
    finishing = true
    active = false
    let dur = duration > 0.05 ? duration : 0.3
    let opt = Self.animationOption(for: curve)

    if cancelled {
      // Fly the overlay back onto the hero's natural resting position in sync
      // with the sheet returning up, then reveal the real hero underneath with
      // zero jump.
      let twin = self.twin
      heroLog(HeroLog.interactive, "syncedCancel dur=\(dur)")
      UIView.animate(
        withDuration: dur,
        delay: 0,
        options: [opt, .allowUserInteraction],
        animations: {
          ov.frame = self.naturalRect
          ov.layer.cornerRadius = self.sourceCorner
        },
        completion: { _ in
          detail.setHiddenForFlight(false)
          twin?.setHiddenForFlight(false)
          ov.removeFromSuperview()
          if self.overlay === ov { self.overlay = nil }
          self.releaseHostIfNeeded()
          HeroRegistry.shared.unmarkInteractivelyHandled(detail)
          detail.emitTransitionEnd()
          self.finishing = false
          // Stay armed + ready so a subsequent drag re-triggers.
        }
      )
      return
    }

    // Commit: the sheet is sliding the rest of the way down. The model frame
    // has jumped to its final state, so the twin's settled frame now reports
    // where the thumbnail rests once the presenter scales back to identity. Fly
    // the overlay there over the SAME duration/curve as the sheet completion,
    // then crossfade to the real (now-settled) thumbnail.
    let twin = self.twin
    let finalRect = nonZero(twin?.settledWindowFrame())
      ?? nonZero(twin?.windowFrame())
      ?? destRect
    heroLog(HeroLog.interactive, "syncedCommit dur=\(dur) final=\(finalRect)")
    UIView.animate(
      withDuration: dur,
      delay: 0,
      options: [opt, .allowUserInteraction],
      animations: {
        ov.frame = finalRect
        ov.layer.cornerRadius = self.destCorner
      },
      completion: { _ in
        twin?.setHiddenForFlight(false)
        UIView.animate(
          withDuration: 0.1,
          animations: { ov.alpha = 0 },
          completion: { _ in
            ov.removeFromSuperview()
            if self.overlay === ov { self.overlay = nil }
            self.releaseHostIfNeeded()
          }
        )
        detail.emitTransitionEnd()
      }
    )
    // Tear down the link + refs now; the animation closures own the overlay.
    //
    // Deliberately DO NOT `unmarkInteractivelyHandled`: the hero is being torn
    // down and its deferred `commitUnregister` must keep early-returning so it
    // doesn't fire a redundant back-flight. `register` clears the stale mark on
    // remount.
    self.detail = nil
    self.twin = nil
    self.ready = false
    self.finishing = false
    stopLink()
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
    if active {
      detail?.setHiddenForFlight(false)
      twin?.setHiddenForFlight(false)
      detail.map { HeroRegistry.shared.unmarkInteractivelyHandled($0) }
    }
    overlay?.removeFromSuperview()
    overlay = nil
    releaseHostIfNeeded()
    detail = nil
    twin = nil
    ready = false
    active = false
    finishing = false
  }

  // MARK: - Helpers.

  /// The presented sheet's active transition coordinator — used to detect
  /// release and match the finish/cancel duration + curve. Walks the responder
  /// chain to the presented VC (the one with a `presentingViewController`); UIKit
  /// sets its coordinator for the duration of an interactive dismissal.
  private static func sheetTransitionCoordinator(_ view: UIView) -> UIViewControllerTransitionCoordinator? {
    var responder: UIResponder? = view
    while let r = responder {
      if let vc = r as? UIViewController, vc.presentingViewController != nil {
        return vc.transitionCoordinator
      }
      responder = r.next
    }
    return nil
  }

  private static func animationOption(for curve: UIView.AnimationCurve) -> UIView.AnimationOptions {
    switch curve {
    case .easeIn: return .curveEaseIn
    case .easeOut: return .curveEaseOut
    case .easeInOut: return .curveEaseInOut
    case .linear: return .curveLinear
    @unknown default: return .curveEaseOut
    }
  }

  private func nonZero(_ rect: CGRect?) -> CGRect? {
    guard let rect = rect, rect != .zero else { return nil }
    return rect
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
}
