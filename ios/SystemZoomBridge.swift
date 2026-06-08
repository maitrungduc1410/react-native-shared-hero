import Foundation
import UIKit

/// Hook point for the iOS 18+ system zoom transition delegation (Phase 6, v2).
///
/// On iOS 18 Apple shipped `UIViewController.preferredTransition = .zoom(...)`
/// — a system-driven zoom transition that pairs perfectly with our shared-hero
/// concept. When all the following hold we can defer to UIKit instead of
/// running our own `FlightEngine`:
///
/// 1. The host view-controller chain is a `UINavigationController`.
/// 2. The transition is a push (or matching pop).
/// 3. `mode === "zoom"` (explicit) or `mode === "auto"` (we pick).
/// 4. `#available(iOS 18, *)`.
///
/// The runtime API requires us to set `preferredTransition` on the
/// destination view-controller *before* it is pushed, plus provide a
/// `sourceViewProvider` callback. That ties our window-overlay model to the
/// host navigator's lifecycle, which we deliberately avoided in v1. So in v1
/// `zoom` / `auto` simply alias to `morph`. This bridge is the place where
/// the v2 implementation will live; keeping it stubbed makes the wiring point
/// obvious for downstream forks and contributors.
@objc public final class SystemZoomBridge: NSObject {
  @objc public static let shared = SystemZoomBridge()

  private override init() { super.init() }

  /// Returns `true` if the running OS supports the system zoom transition.
  @objc public var isAvailable: Bool {
    if #available(iOS 18, *) { return true }
    return false
  }

  /// Walks up the responder chain from `view` to find the nearest enclosing
  /// `UINavigationController`. Returns `nil` when the view is hosted in a
  /// modal, sheet, or anything else that wouldn't qualify for the system zoom.
  @objc public func navigationController(for view: UIView) -> UINavigationController? {
    var responder: UIResponder? = view
    while let r = responder {
      if let vc = r as? UIViewController, let nav = vc.navigationController {
        return nav
      }
      responder = r.next
    }
    return nil
  }

  /// Stub for the v2 wiring. Returns `true` if the caller should skip the
  /// `FlightEngine` and let UIKit drive the transition instead. In v1 this is
  /// always `false` — the FlightEngine runs unconditionally and `zoom`/`auto`
  /// are aliased to `morph`.
  @objc public func tryInstallSystemZoom(
    sourceView: UIView,
    mode: String
  ) -> Bool {
    // Intentionally unused; reserved for v2.
    _ = sourceView
    _ = mode
    return false
  }
}
