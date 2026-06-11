import Foundation
import UIKit

/// Hook point for the iOS 18+ system zoom transition delegation (Phase 6, v2).
///
/// iOS 18's `UIViewController.preferredTransition = .zoom(...)` is a
/// system-driven zoom that maps onto our shared-hero concept; when all hold we
/// could defer to UIKit instead of `FlightEngine`:
///   1. The host VC chain is a `UINavigationController`.
///   2. The transition is a push (or matching pop).
///   3. `mode === "zoom"` (explicit) or `mode === "auto"` (we pick).
///   4. `#available(iOS 18, *)`.
///
/// But the API needs `preferredTransition` set on the destination VC *before*
/// the push plus a `sourceViewProvider` callback, tying our window-overlay
/// model to the host navigator's lifecycle — which v1 deliberately avoids. So
/// v1 aliases `zoom`/`auto` to `morph`; this stub marks where the v2 wiring
/// will live.
@objc public final class SystemZoomBridge: NSObject {
  @objc public static let shared = SystemZoomBridge()

  private override init() { super.init() }

  /// Returns `true` if the running OS supports the system zoom transition.
  @objc public var isAvailable: Bool {
    if #available(iOS 18, *) { return true }
    return false
  }

  /// Nearest enclosing `UINavigationController` up the responder chain, or `nil`
  /// for a modal/sheet/other context that wouldn't qualify for system zoom.
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

  /// v2 stub. Returns `true` if the caller should skip `FlightEngine` and let
  /// UIKit drive the transition; always `false` in v1 (FlightEngine runs
  /// unconditionally, `zoom`/`auto` alias to `morph`).
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
