import Foundation
import QuartzCore
import UIKit

/// Runs a single shared-hero flight.
///
/// Modes:
/// - `snapshot` — cheap clone, translate+scale, crossfade.
/// - `morph`    — corner radius and background colour also interpolate
///                (Material container transform).
/// - `shuttle`  — alias for `snapshot`, reserved for the v2 native portal.
///
/// Motion paths:
/// - `linear` (default) — straight rectangular interpolation.
/// - `arc`              — Material-y curved arc through the centre offset.
///
/// Timing models:
/// - Time-based (default) via `UIViewPropertyAnimator` with an easing curve.
/// - Spring-based when `springStiffness`/`springMass` are non-zero, via
///   `UISpringTimingParameters` for native iOS spring feel.
@objc public final class FlightEngine: NSObject {
  @objc public static let shared = FlightEngine()

  private override init() { super.init() }

  private struct ViewGeometry {
    let frame: CGRect
    let cornerRadius: CGFloat
    let backgroundColor: UIColor
  }

  /// Runs a flight from a previously-captured [source] snapshot to a still-
  /// mounted [dest] view. Capturing the source up-front means the engine
  /// survives the host navigator detaching / moving the original source view
  /// during the navigation animation.
  ///
  /// `sourceView` is the live source `SharedHeroViewImpl` (when available);
  /// it's un-hidden after the soft handoff so that when the user navigates
  /// back the source view's real content is visible. Pass `nil` for flights
  /// where the source no longer exists (e.g. the in-place match path).
  ///
  /// `destFrameOverride` lets the caller pin the flight's landing rect
  /// instead of re-reading `dest.settledWindowFrame()` here. The registry's
  /// poll loop uses this to pass the rect it just verified as stable across
  /// runloop ticks, so we don't re-sample a transient layout value that
  /// happens to differ from the verified one (e.g. when
  /// `react-native-screens` re-attaches the previous screen during an
  /// interactive pop and Fabric is still committing the chain's positions).
  ///
  /// `onAllDone` is invoked when the flight has fully completed (after the
  /// soft-handoff fade-out). Caller uses this to release any per-flight
  /// state (e.g. duplicate-suppression bookkeeping in the registry).
  func run(
    from source: HeroSnapshot,
    sourceView: SharedHeroViewImpl?,
    to dest: SharedHeroViewImpl,
    destFrameOverride: CGRect? = nil,
    onAllDone: (() -> Void)? = nil
  ) {
    let cfg = dest.config

    let endGeo: ViewGeometry
    if let frame = destFrameOverride {
      endGeo = ViewGeometry(
        frame: frame,
        cornerRadius: dest.effectiveCornerRadius(),
        backgroundColor: dest.effectiveBackgroundColor()
      )
    } else {
      endGeo = geometry(of: dest)
    }
    NSLog("[SharedHeroFlight] run sourceFrame=\(source.frame) destFrame=\(endGeo.frame) destSettled=\(dest.settledWindowFrame()) destVisible=\(dest.windowFrame()) override=\(destFrameOverride != nil) mode=\(cfg.mode) sourceHasImage=\(source.image != nil)")
    if endGeo.frame == .zero {
      NSLog("[SharedHeroFlight] abort: dest not laid out")
      dest.setHiddenForFlight(false)
      sourceView?.setHiddenForFlight(false)
      onAllDone?()
      return
    }
    let initial = ViewGeometry(
      frame: source.frame,
      cornerRadius: source.cornerRadius,
      backgroundColor: source.backgroundColor
    )

    // NOTE: in v1 we only fly the source bitmap. Capturing the destination
    // bitmap here would require temporarily un-hiding `dest.contentView`,
    // which causes a one-frame flicker because Core Animation can commit the
    // un-hide before our re-hide. We use the source as both ends of the
    // crossfade; the destination's real content takes over the moment the
    // flight completes.
    guard source.image != nil else {
      NSLog("[SharedHeroFlight] abort: no source bitmap")
      dest.setHiddenForFlight(false)
      sourceView?.setHiddenForFlight(false)
      onAllDone?()
      return
    }

    let overlay = OverlayHost.shared.host()
    NSLog("[SharedHeroFlight] overlay host obtained frame=\(overlay.frame) window=\(String(describing: overlay.window))")

    let flightView = UIView(frame: initial.frame)
    flightView.backgroundColor = .clear
    flightView.clipsToBounds = true
    flightView.layer.cornerRadius = initial.cornerRadius
    flightView.layer.masksToBounds = true

    // `zoom` / `auto` reserved for iOS 18+ system zoom delegation (v2). For
    // now they alias to `morph` so consumers can adopt the API surface and
    // benefit automatically once the imperative pre-push wiring lands.
    let isMorph = cfg.mode == "morph"
      || cfg.mode == "zoom"
      || cfg.mode == "auto"
    if isMorph {
      flightView.backgroundColor = initial.backgroundColor
    }

    let sourceImageView: UIImageView?
    if let img = source.image {
      let iv = UIImageView(image: img)
      iv.frame = flightView.bounds
      iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      iv.contentMode = .scaleAspectFill
      flightView.addSubview(iv)
      sourceImageView = iv
    } else {
      sourceImageView = nil
    }

    // No dest snapshot in v1 — see note above.
    let destImageView: UIImageView? = nil

    overlay.addSubview(flightView)
    NSLog("[SharedHeroFlight] flightView added frame=\(flightView.frame) subviews=\(flightView.subviews.count) overlaySubviews=\(overlay.subviews.count)")

    dest.setHiddenForFlight(true)
    dest.emitTransitionStart()

    // Soft handoff:
    //  1. Geometric flight runs (frame / cornerRadius / bg).
    //  2. Reveal the real destination content (still blank if its <Image> is
    //     loading) UNDER the flight view.
    //  3. Fade the flight view out over a short window so the user sees either
    //     the loaded dest emerging through the fade, or a gentle fade to blank
    //     instead of a hard pop.
    //  4. Un-hide the source so when the user navigates back its real content
    //     is in place (the previous screen is off-screen by now, so the
    //     un-hide is invisible).
    // The actual soft-handoff: reveal the real destination hero UNDER the
    // overlay, then crossfade the overlay out.
    let reveal: () -> Void = { [weak dest, weak sourceView] in
      dest?.setHiddenForFlight(false)
      UIView.animate(
        withDuration: 0.18,
        delay: 0,
        options: [.curveEaseOut, .allowUserInteraction],
        animations: {
          flightView.alpha = 0
        },
        completion: { _ in
          flightView.removeFromSuperview()
          sourceView?.setHiddenForFlight(false)
          OverlayHost.shared.releaseHost()
          dest?.emitTransitionEnd()
          onAllDone?()
        }
      )
    }

    let completion: () -> Void = reveal

    if cfg.motionPath == "arc" {
      runArcFlight(
        flightView: flightView,
        from: initial,
        to: endGeo,
        cfg: cfg,
        sourceSnapshot: sourceImageView,
        destSnapshot: destImageView,
        isMorph: isMorph,
        completion: completion
      )
    } else {
      runLinearFlight(
        flightView: flightView,
        from: initial,
        to: endGeo,
        cfg: cfg,
        sourceSnapshot: sourceImageView,
        destSnapshot: destImageView,
        isMorph: isMorph,
        completion: completion
      )
    }
  }

  // MARK: - Linear path.

  private func runLinearFlight(
    flightView: UIView,
    from initial: ViewGeometry,
    to endGeo: ViewGeometry,
    cfg: SharedHeroConfig,
    sourceSnapshot: UIView?,
    destSnapshot: UIView?,
    isMorph: Bool,
    completion: @escaping () -> Void
  ) {
    let duration: TimeInterval = cfg.usesSpring ? 0.32 : max(0.05, TimeInterval(cfg.duration) / 1000.0)

    // UIViewPropertyAnimator does NOT animate `layer.cornerRadius`, so without
    // an explicit CABasicAnimation the corner snaps to the end value
    // instantly. Drive it with a CA animation that piggybacks the same
    // duration and easing as the property animator.
    if initial.cornerRadius != endGeo.cornerRadius {
      let cornerAnim = CABasicAnimation(keyPath: "cornerRadius")
      cornerAnim.fromValue = initial.cornerRadius
      cornerAnim.toValue = endGeo.cornerRadius
      cornerAnim.duration = duration
      cornerAnim.timingFunction = Self.caTimingFunction(cfg.easing)
      flightView.layer.add(cornerAnim, forKey: "shFlight.cornerRadius")
      flightView.layer.cornerRadius = endGeo.cornerRadius
    }

    let animations = {
      flightView.frame = endGeo.frame
      if isMorph {
        flightView.backgroundColor = endGeo.backgroundColor
      }
      Self.applyFinalFade(cfg.fadeMode, source: sourceSnapshot, dest: destSnapshot)
    }

    let animator: UIViewPropertyAnimator
    if cfg.usesSpring {
      let m: CGFloat = cfg.springMass > 0 ? cfg.springMass : 1
      let s: CGFloat = cfg.springStiffness > 0 ? cfg.springStiffness : 180
      let d: CGFloat = cfg.springDamping > 0 ? cfg.springDamping : 20
      let initialVel = CGVector.zero
      let timing = UISpringTimingParameters(mass: m, stiffness: s, damping: d, initialVelocity: initialVel)
      animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
      animator.addAnimations(animations)
    } else {
      animator = UIViewPropertyAnimator(duration: duration, curve: Self.easing(cfg.easing), animations: animations)
    }
    animator.addCompletion { _ in completion() }
    animator.startAnimation()
  }

  // MARK: - Arc path (driven by CADisplayLink for per-frame control).

  private func runArcFlight(
    flightView: UIView,
    from initial: ViewGeometry,
    to endGeo: ViewGeometry,
    cfg: SharedHeroConfig,
    sourceSnapshot: UIView?,
    destSnapshot: UIView?,
    isMorph: Bool,
    completion: @escaping () -> Void
  ) {
    let duration: TimeInterval = max(0.05, TimeInterval(cfg.duration) / 1000.0)
    let startCenter = CGPoint(x: initial.frame.midX, y: initial.frame.midY)
    let endCenter = CGPoint(x: endGeo.frame.midX, y: endGeo.frame.midY)
    // Material-style arc: when moving down, arc curves up-then-down; when
    // moving up, arc curves up. The control point is the corner of the
    // rectangle formed by the two centres, biased toward the larger of dx/dy.
    let dx = endCenter.x - startCenter.x
    let dy = endCenter.y - startCenter.y
    let controlPoint: CGPoint = abs(dx) > abs(dy)
      ? CGPoint(x: endCenter.x, y: startCenter.y)
      : CGPoint(x: startCenter.x, y: endCenter.y)

    var elapsed: CFTimeInterval = 0
    var lastTick: CFTimeInterval = CACurrentMediaTime()
    let driver = DisplayLinkDriver()

    driver.start { tick in
      elapsed += tick - lastTick
      lastTick = tick
      let raw = min(1.0, elapsed / duration)
      let t = CGFloat(Self.easingFunction(cfg.easing)(raw))

      let p = Self.quadraticBezier(start: startCenter, control: controlPoint, end: endCenter, t: t)
      let w = initial.frame.width + (endGeo.frame.width - initial.frame.width) * t
      let h = initial.frame.height + (endGeo.frame.height - initial.frame.height) * t
      flightView.frame = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
      flightView.layer.cornerRadius = initial.cornerRadius + (endGeo.cornerRadius - initial.cornerRadius) * t
      if isMorph {
        flightView.backgroundColor = Self.lerp(initial.backgroundColor, endGeo.backgroundColor, t)
      }
      Self.applyTimeFade(cfg.fadeMode, source: sourceSnapshot, dest: destSnapshot, t: t)

      if raw >= 1.0 {
        driver.stop()
        completion()
      }
    }
  }

  // MARK: - Helpers.

  private func geometry(of view: SharedHeroViewImpl) -> ViewGeometry {
    // Use the SETTLED frame for the destination. During a navigation
    // transition (e.g. a native-stack pop with parallax), the dest's screen
    // container can have an in-progress translation transform applied. The
    // raw `windowFrame()` would reflect that transient position and the
    // flight would land in the wrong place. `settledWindowFrame()` resolves
    // to where the view will land once the host's transition completes.
    let frame = view.settledWindowFrame()
    // Read radius / background through the view's effective-style helpers
    // rather than `contentView.layer.cornerRadius` directly. React applies
    // `borderRadius` / `backgroundColor` to the Fabric host (our shim,
    // `contentView.superview`) — reading only `contentView` here used to
    // resolve `radius = 0` for the common
    // `<SharedHero style={{ borderRadius: 16 }}>` pattern, which made the
    // forward-flight overlay snap to square at t=0 (the
    // `if initial.cornerRadius != endGeo.cornerRadius` branch below would
    // skip the `CABasicAnimation` and `flightView.layer.cornerRadius` was
    // already 0). See `SharedHeroViewImpl.effectiveCornerRadius()`.
    return ViewGeometry(
      frame: frame,
      cornerRadius: view.effectiveCornerRadius(),
      backgroundColor: view.effectiveBackgroundColor()
    )
  }

  private static func easing(_ name: String) -> UIView.AnimationCurve {
    switch name {
    case "linear": return .linear
    case "easeIn": return .easeIn
    case "easeOut": return .easeOut
    case "easeInOut", "standard", "emphasized": return .easeInOut
    default: return .easeInOut
    }
  }

  private static func easingFunction(_ name: String) -> (Double) -> Double {
    switch name {
    case "linear":
      return { $0 }
    case "easeIn":
      return { $0 * $0 }
    case "easeOut":
      return { 1 - (1 - $0) * (1 - $0) }
    case "easeInOut", "standard":
      return { $0 < 0.5 ? 2 * $0 * $0 : 1 - pow(-2 * $0 + 2, 2) / 2 }
    case "emphasized":
      // Material-3 emphasized: faster start, slow end.
      return { 1 - pow(1 - $0, 3) }
    default:
      return { $0 < 0.5 ? 2 * $0 * $0 : 1 - pow(-2 * $0 + 2, 2) / 2 }
    }
  }

  private static func quadraticBezier(
    start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat
  ) -> CGPoint {
    let it = 1 - t
    let x = it * it * start.x + 2 * it * t * control.x + t * t * end.x
    let y = it * it * start.y + 2 * it * t * control.y + t * t * end.y
    return CGPoint(x: x, y: y)
  }

  private static func lerp(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return UIColor(
      red: ar + (br - ar) * t,
      green: ag + (bg - ag) * t,
      blue: ab + (bb - ab) * t,
      alpha: aa + (ba - aa) * t
    )
  }

  private static func applyFinalFade(_ mode: String, source: UIView?, dest: UIView?) {
    // Without a dest snapshot to fade into, fading the source out leaves the
    // flying view invisible by the end of the flight. Keep source at full
    // alpha and let the post-flight handoff do the smooth reveal instead.
    guard dest != nil else { return }
    switch mode {
    case "in": dest?.alpha = 1
    case "out": source?.alpha = 0
    case "through":
      source?.alpha = 0
      dest?.alpha = 1
    case "cross":
      fallthrough
    default:
      source?.alpha = 0
      dest?.alpha = 1
    }
  }

  private static func applyTimeFade(_ mode: String, source: UIView?, dest: UIView?, t: CGFloat) {
    guard dest != nil else { return }
    switch mode {
    case "in":
      dest?.alpha = t
    case "out":
      source?.alpha = 1 - t
    case "through":
      if t < 0.5 {
        source?.alpha = 1 - (t / 0.5)
        dest?.alpha = 0
      } else {
        source?.alpha = 0
        dest?.alpha = (t - 0.5) / 0.5
      }
    case "cross":
      fallthrough
    default:
      source?.alpha = 1 - t
      dest?.alpha = t
    }
  }

  private static func caTimingFunction(_ name: String) -> CAMediaTimingFunction {
    switch name {
    case "linear":
      return CAMediaTimingFunction(name: .linear)
    case "easeIn":
      return CAMediaTimingFunction(name: .easeIn)
    case "easeOut":
      return CAMediaTimingFunction(name: .easeOut)
    case "easeInOut", "standard":
      return CAMediaTimingFunction(name: .easeInEaseOut)
    case "emphasized":
      // Material-3 emphasized: faster start, slow tail.
      return CAMediaTimingFunction(controlPoints: 0.05, 0.7, 0.1, 1.0)
    default:
      return CAMediaTimingFunction(name: .easeInEaseOut)
    }
  }
}

/// CADisplayLink-backed per-frame ticker used by the arc-flight path.
private final class DisplayLinkDriver {
  private var link: CADisplayLink?
  private var onTick: ((CFTimeInterval) -> Void)?

  func start(onTick: @escaping (CFTimeInterval) -> Void) {
    self.onTick = onTick
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
    onTick = nil
  }

  @objc private func tick() {
    guard let link = link else { return }
    onTick?(link.timestamp)
  }
}
