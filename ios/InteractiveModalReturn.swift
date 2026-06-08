import Foundation
import QuartzCore
import UIKit

/// Drives an INTERACTIVE shared-hero return when a `react-native-screens`
/// sheet modal (`presentation: 'modal'` / `'formSheet'`, i.e. a
/// `UISheetPresentationController`) is dismissed by the swipe-down gesture.
///
/// ## Why this exists
///
/// A button dismiss works through the normal registry back-flight because
/// React-Navigation's `goBack()` unmounts the modal screen at the START of the
/// dismiss, so the flight overlaps the slide. A SWIPE dismiss is the opposite:
/// UIKit drives the sheet interactively and React-Navigation only unmounts the
/// screen AFTER the dismiss fully completes — by then the list is already
/// revealed and any flight we start is hopelessly late. We can't hook UIKit's
/// interactive sheet transition (RNS owns the presentation controller), so we
/// instead OBSERVE the sheet's real motion and drive our own overlay copy.
///
/// ## Mechanism (no prediction, always in sync with the real sheet)
///
/// While a sheet-hosted detail hero is on-window we run a `CADisplayLink` that
/// reads the hero's LIVE window position each frame. We capture its resting
/// ("natural") window position once the present animation settles, then:
///
///   * `translation = live.minY - natural.minY` is exactly how far the sheet
///     has been dragged down (works whether UIKit moves the sheet by transform
///     or by frame — we only ever read `windowFrame()`).
///   * Once a downward drag is detected we hide the real hero + the list
///     thumbnail and add an overlay snapshot. Each frame we move the overlay
///     from `natural + translation` (it tracks the finger, so it stays over the
///     real hero and the empty-card "hole" is mostly covered) toward the list
///     thumbnail as the dismiss progresses.
///   * If the hero leaves the window (sheet committed to dismiss) we land the
///     overlay on the thumbnail and hand off to the real list hero. If the
///     sheet returns to rest (drag cancelled) we restore the hero. The release
///     decision is UIKit's — we just follow whatever the sheet actually does.
///
/// ## Known limitation
///
/// The native sheet card still slides as a unit, so the hero is visually
/// "peeled" out of it. The finger-tracking mapping keeps the overlay over the
/// real hero for most of the drag, minimising the visible gap, but it can't be
/// fully eliminated without owning the sheet's transition controller.
@objc public final class InteractiveModalReturn: NSObject {
  @objc public static let shared = InteractiveModalReturn()
  private override init() { super.init() }

  // MARK: - Tunables.

  /// Frames of <0.5pt position change before we treat the present animation as
  /// settled and capture the hero's natural resting frame.
  private static let settleStableFrames = 3
  /// Downward translation (points) that arms the interactive overlay. Small so
  /// the hero starts tracking almost immediately, but non-zero so layout
  /// jitter doesn't trigger it.
  private static let activateThreshold: CGFloat = 6
  /// Translation at/below which an active drag is considered cancelled (sheet
  /// returned to rest).
  private static let cancelThreshold: CGFloat = 2

  // MARK: - Session state.

  private weak var detail: SharedHeroViewImpl?
  private weak var twin: SharedHeroViewImpl?

  private var link: CADisplayLink?
  /// Present animation has settled and `naturalRect` is valid.
  private var ready = false
  /// A downward drag is in progress and the overlay is live.
  private var active = false

  private var overlay: UIView?
  private var hostRetained = false

  private var naturalRect: CGRect = .zero
  private var sourceCorner: CGFloat = 0
  private var destRect: CGRect = .zero
  private var destCorner: CGFloat = 0
  private var dismissRef: CGFloat = 1

  private var lastY: CGFloat = .greatestFiniteMagnitude
  private var stableFrames = 0

  /// The tracked hero has attached to a window at least once. Until then a
  /// `window == nil` reading just means the modal is still presenting (its
  /// content is off-window during the present animation) — NOT a dismiss.
  private var everAttached = false
  /// Wall-clock deadline for the first attach, so a flight that is queued for a
  /// destination that never attaches (e.g. aborted) doesn't leave the link
  /// running forever.
  private var attachDeadline: CFTimeInterval = 0
  private static let maxAttachWaitSeconds: CFTimeInterval = 8

  // MARK: - Arming (called from HeroRegistry.runTwinFlight).

  /// Arm interactive tracking for a freshly-pushed `detail` hero whose return
  /// destination is `twin` (the source/list hero). Cheap to call for every
  /// twin flight: if the detail turns out NOT to be inside a swipe-dismissable
  /// sheet (e.g. a plain native-stack push) we stand down as soon as it
  /// settles on-window.
  func arm(detail: SharedHeroViewImpl, twin: SharedHeroViewImpl) {
    // Tear down any previous (un-finalised) session without reversing it.
    disarm()
    self.detail = detail
    self.twin = twin
    self.ready = false
    self.active = false
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
    guard let detail = detail else { disarm(); return }

    // Hero off-window. Two very different cases:
    //   * Before the first attach → the modal is still presenting (its content
    //     is off-window during the present animation). Keep waiting, bounded by
    //     `attachDeadline` so an aborted/never-attached flight doesn't spin.
    //   * After having been attached → the modal finished dismissing.
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
      // Wait for the present animation to settle before sampling a natural
      // resting frame. Detect settle as "vertical position stopped moving".
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

    let translation = live.minY - naturalRect.minY

    if !active {
      if translation > Self.activateThreshold {
        activate()
      }
      return
    }

    // Cancelled: sheet returned to rest with the overlay still live.
    if translation <= Self.cancelThreshold {
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

    // Destination = the list thumbnail. It sits behind the sheet in the same
    // window, but iOS recedes/scales the presenter under a pageSheet, so its
    // LIVE `windowFrame()` is transform-distorted. Use `settledWindowFrame()`
    // (ancestor transforms reset) to get the resting position the thumbnail
    // will occupy once the presenter scales back to identity on dismiss.
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
    // Make the registry's unregister back-flight stand down — we own this
    // transition now (mirrors the `alreadyFlighted` source-flight guard).
    HeroRegistry.shared.markInteractivelyHandled(detail)
    detail.emitTransitionStart()
    active = true
    NSLog("[SharedHeroInteractive] activate detail=\(ObjectIdentifier(detail)) natural=\(naturalRect) dest=\(destRect) dismissRef=\(dismissRef)")
  }

  private func driveOverlay(translation: CGFloat, progress p: CGFloat) {
    guard let ov = overlay else { return }
    // Follow the finger (source offset by the live translation) early, converge
    // to the thumbnail as the dismiss completes. Early in the drag this keeps
    // the overlay over the real (hidden) hero so the empty-card gap is hidden;
    // near the end it peels into the list.
    let followed = naturalRect.offsetBy(dx: 0, dy: translation)
    ov.frame = Self.lerpRect(followed, destRect, p)
    ov.layer.cornerRadius = sourceCorner + (destCorner - sourceCorner) * p
  }

  private func finalizeDismiss() {
    guard let ov = overlay else { disarm(); return }
    let twin = self.twin
    let detail = self.detail
    NSLog("[SharedHeroInteractive] finalizeDismiss dest=\(destRect)")
    UIView.animate(
      withDuration: 0.18,
      delay: 0,
      options: [.curveEaseOut],
      animations: {
        ov.frame = self.destRect
        ov.layer.cornerRadius = self.destCorner
      },
      completion: { _ in
        // Reveal the real list thumbnail, then fade the overlay out.
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
    // Deliberately DO NOT `unmarkInteractivelyHandled` here: the hero is being
    // torn down and its deferred `commitUnregister` (next runloop tick) must
    // keep taking the `alreadyFlighted` early-return branch so it does not fire
    // a second, redundant back-flight. The stale `alreadyFlighted` entry is
    // cleared by `register` when the view (or its recycled address) next mounts.
    self.detail = nil
    self.twin = nil
    self.active = false
    self.ready = false
    stopLink()
  }

  private func finalizeCancel() {
    guard let detail = detail else { disarm(); return }
    NSLog("[SharedHeroInteractive] finalizeCancel")
    // The sheet snapped back to rest, so the real hero is already at
    // `naturalRect` and the overlay (translation≈0, progress≈0) sits on top of
    // it — un-hide and remove with no visible jump.
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

  private func releaseHostIfNeeded() {
    if hostRetained {
      OverlayHost.shared.releaseHost()
      hostRetained = false
    }
  }

  /// Tear down the session immediately, without reversing or completing a
  /// transition. Used when arming a new session or when the tracked hero is no
  /// longer eligible (deallocated, not a sheet, non-interactive dismiss).
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
  }

  // MARK: - Helpers.

  /// True if `view` is hosted inside a presented sheet (`pageSheet` /
  /// `formSheet`) — the only modal styles UIKit lets the user swipe to dismiss.
  /// `internal` (not `private`) so `InteractiveStackPop` can reuse it to
  /// exclude sheet contexts from the native-stack pop path.
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
