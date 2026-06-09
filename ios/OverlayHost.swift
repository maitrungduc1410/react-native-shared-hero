import Foundation
import UIKit

/// A library-owned UIWindow that hosts flying snapshots above every
/// presentation context (modal, transparentModal, sheet, alert).
///
/// The window is created lazily on first hero registration and **stays
/// visible forever after** — toggling `UIWindow.isHidden` per flight causes
/// a one-frame "window not yet on screen" gap at the start of each flight,
/// during which the user sees the source view's parent background (white)
/// instead of the flight overlay. The symptom is a quick white flash at
/// the tapped image's position before the flight overlay catches up.
///
/// Because the window is transparent (`backgroundColor = .clear`) and
/// non-interactive (`isUserInteractionEnabled = false`), keeping it
/// permanently visible has no visual or input cost when no flights are
/// active. We defer status-bar and rotation queries to the underlying app's
/// topmost view controller (see [OverlayRootViewController]) so the app's
/// preferences still drive system chrome.
@objc public final class OverlayHost: NSObject {
  @objc public static let shared = OverlayHost()

  private var window: UIWindow?
  private var activeFlightCount: Int = 0

  private override init() {
    super.init()
  }

  /// Pre-create the overlay window so it has time to complete its first
  /// render pass on a separate UIWindow render server flush before any
  /// flight actually adds a subview. Called from `HeroRegistry.register`
  /// so the window is up well before the user's first tap.
  @objc public func prepare() {
    ensureWindow()
  }

  /// Returns the overlay's host view. Must be called on the main thread.
  func host() -> UIView {
    ensureWindow()
    activeFlightCount += 1
    let win = window!
    let root = win.rootViewController!.view!
    heroLog(HeroLog.overlay, "host count=\(activeFlightCount) winFrame=\(win.frame) winLevel=\(win.windowLevel.rawValue) rootFrame=\(root.frame)")
    return root
  }

  /// Decrement the active-flight counter. The window stays visible — see
  /// the type-level doc comment.
  func releaseHost() {
    activeFlightCount = max(0, activeFlightCount - 1)
    heroLog(HeroLog.overlay, "release count=\(activeFlightCount)")
  }

  private func ensureWindow() {
    if window != nil { return }
    let scene: UIWindowScene? = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })
      ?? UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first
    let frame = scene?.coordinateSpace.bounds ?? UIScreen.main.bounds

    let win: UIWindow
    if let scene = scene {
      win = UIWindow(windowScene: scene)
    } else {
      win = UIWindow(frame: frame)
    }
    win.frame = frame
    win.windowLevel = UIWindow.Level.alert + 1
    win.backgroundColor = .clear
    win.isUserInteractionEnabled = false
    let root = OverlayRootViewController()
    win.rootViewController = root
    root.view.frame = frame
    root.view.backgroundColor = .clear
    // Show the window immediately. This is the key change vs. the previous
    // version: by leaving the window visible (just transparent + empty) the
    // very first flight doesn't pay the "window appearing for the first
    // time" frame cost that produced the white-flash artifact.
    win.isHidden = false
    heroLog(HeroLog.overlay, "window created frame=\(frame) scene=\(String(describing: scene))")
    self.window = win
  }
}

/// Transparent host VC that defers status-bar / rotation preferences to the
/// underlying app's topmost view controller. Without this deferral, our
/// always-visible overlay window (which is the topmost window in the app)
/// would force its own — typically wrong — preferences onto the system.
private final class OverlayRootViewController: UIViewController {
  override func loadView() {
    let v = PassThroughView()
    v.backgroundColor = .clear
    self.view = v
  }

  /// The topmost view controller in any window OTHER than our overlay
  /// window. Walks `presentedViewController` so a modal/sheet on top of the
  /// app's root counts as the topmost.
  private var underlyingTopVC: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    for scene in scenes {
      guard let ws = scene as? UIWindowScene else { continue }
      let underlyingWindows = ws.windows
        .filter { $0 !== self.view.window && !$0.isHidden }
        .sorted(by: { $0.windowLevel < $1.windowLevel })
      guard let top = underlyingWindows.last else { continue }
      var vc = top.rootViewController
      while let presented = vc?.presentedViewController, !presented.isBeingDismissed {
        vc = presented
      }
      if vc != nil { return vc }
    }
    return nil
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return underlyingTopVC?.preferredStatusBarStyle ?? super.preferredStatusBarStyle
  }

  override var prefersStatusBarHidden: Bool {
    return underlyingTopVC?.prefersStatusBarHidden ?? super.prefersStatusBarHidden
  }

  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
    return underlyingTopVC?.preferredStatusBarUpdateAnimation ?? super.preferredStatusBarUpdateAnimation
  }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    return underlyingTopVC?.supportedInterfaceOrientations ?? .all
  }

  override var prefersHomeIndicatorAutoHidden: Bool {
    return underlyingTopVC?.prefersHomeIndicatorAutoHidden ?? super.prefersHomeIndicatorAutoHidden
  }

  override var childForStatusBarStyle: UIViewController? {
    return underlyingTopVC
  }

  override var childForStatusBarHidden: UIViewController? {
    return underlyingTopVC
  }

  override var childForHomeIndicatorAutoHidden: UIViewController? {
    return underlyingTopVC
  }
}

/// Lets touches fall through to the key window so the overlay never blocks
/// user input.
private final class PassThroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    return nil
  }
}
