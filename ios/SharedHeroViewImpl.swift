import Foundation
import UIKit

/// Per-view configuration extracted from Fabric props on each update.
@objc public class SharedHeroConfig: NSObject {
  @objc public var heroId: String = ""
  @objc public var heroNamespace: String = "default"
  @objc public var mode: String = "snapshot"
  @objc public var duration: Int = 320
  @objc public var springDamping: CGFloat = 0
  @objc public var springStiffness: CGFloat = 0
  @objc public var springMass: CGFloat = 0
  @objc public var fadeMode: String = "cross"
  @objc public var easing: String = "standard"
  @objc public var motionPath: String = "linear"
  @objc public var enabled: Bool = true
  /// When false, unregister does a quiet teardown — no return/back-flight.
  /// Defaults true.
  @objc public var returnFlightEnabled: Bool = true

  public override init() {}

  public var usesSpring: Bool {
    return springStiffness > 0 && springMass > 0
  }
}

/// Callback the Obj-C++ shim sets to forward direct events back through Fabric.
public typealias SharedHeroEventEmitter = (_ id: String, _ namespace: String) -> Void

/// Swift companion that owns the view's hero behaviour. The Obj-C++ shim is a
/// thin `RCTViewComponentView` that creates one of these per Fabric view and
/// forwards `updateProps` / lifecycle.
@objc public class SharedHeroViewImpl: NSObject {
  /// The container that hosts the Fabric children. Mounted as the shim's
  /// `contentView`.
  @objc public let contentView: UIView

  @objc public var config: SharedHeroConfig

  /// Set by the shim; fires `(id, namespace)` when the source's outbound flight starts.
  @objc public var onTransitionStart: SharedHeroEventEmitter?
  /// Invoked with `(id, namespace)` when the destination view's inbound flight ends.
  @objc public var onTransitionEnd: SharedHeroEventEmitter?

  /// Snapshot key currently held by the registry, used to detect prop changes.
  private var registeredKey: String?

  @objc public override init() {
    self.contentView = UIView()
    self.contentView.clipsToBounds = false
    self.config = SharedHeroConfig()
    super.init()
  }

  /// Called by the shim after `updateProps`.
  @objc public func didUpdateConfig() {
    // If the id or namespace changed while we're registered, re-register.
    let newKey = "\(config.heroNamespace)::\(config.heroId)"
    if registeredKey != nil && registeredKey != newKey {
      HeroRegistry.shared.unregister(self)
      registeredKey = nil
      if config.enabled, !config.heroId.isEmpty {
        HeroRegistry.shared.register(self)
        registeredKey = newKey
      }
    } else if config.enabled, !config.heroId.isEmpty, registeredKey == nil {
      HeroRegistry.shared.register(self)
      registeredKey = newKey
    } else if !config.enabled, registeredKey != nil {
      HeroRegistry.shared.unregister(self)
      registeredKey = nil
    }
  }

  /// Called from the shim when the view is mounted into the window.
  @objc public func didMoveToWindow(_ window: UIWindow?) {
    heroLog(HeroLog.impl, "didMoveToWindow window=\(window != nil) view=\(ObjectIdentifier(self)) id=\(config.heroId) ns=\(config.heroNamespace) bounds=\(contentView.bounds) stashed=\(stashedSnapshot != nil)")
    if window != nil, config.enabled, !config.heroId.isEmpty {
      // Intentionally DO NOT wipe `stashedSnapshot` here. Clearing it on
      // re-attach left a fragile window: if the next forward flight asked for
      // a snapshot before Fabric committed our first layout (window non-nil but
      // `bounds == .zero` for one tick), the live capture AND stash were both
      // nil and `runTwinFlight` aborted with no flight ("detail fades in
      // without the hero"). Keeping the last good capture as a fallback lets
      // the flight fire with slightly-stale content (invisible in a flight's
      // first frames). Refreshed by every `captureSnapshotRaw()`.
      if registeredKey == nil {
        HeroRegistry.shared.register(self)
        registeredKey = "\(config.heroNamespace)::\(config.heroId)"
      }
      // Record the stable frame on attach too: on the INITIAL mount the sole
      // `updateLayoutMetrics` fires before we're on-window, so the recorder it
      // schedules bails (window == nil) and never re-runs, leaving
      // `lastStableWindowFrame == .zero` for the first in-place toggle (which
      // then uses the torn live capture and starts ~100pt off). Triggering here
      // guarantees a valid stable frame once on-window.
      recordStableFrameSoon()
      // For a recycled in-place view, Fabric applies the NEW layout BEFORE
      // re-attaching us (its `updateLayoutMetrics` fired while `window == nil`,
      // so that trigger bailed). Attach is thus the first on-window moment the
      // resize is visible: give the registry a synchronous chance to hide+fly
      // in THIS transaction, before the new state renders uncovered (the
      // "tap → flash new size → rewind → animate" glitch). `notifyLayoutReady`
      // no-ops unless we're watched for an in-place resize AND the size changed.
      HeroRegistry.shared.notifyLayoutReady(self)
    } else if window == nil {
      if registeredKey != nil {
        HeroRegistry.shared.unregister(self)
        registeredKey = nil
      }
    }
  }

  /// Called from the shim's `willMoveToWindow:` as the view leaves its window.
  /// Stashes a snapshot while still on-window so the back-flight keeps a valid
  /// source even when the navigator's mount/unmount order loses the twin match
  /// (e.g. the dest re-attaches AFTER the source unmounts, by which point a
  /// capture would see `window == nil` and return nil).
  @objc public func prepareToLeaveWindow() {
    guard config.enabled, !config.heroId.isEmpty else { return }
    if let snap = captureSnapshot() {
      stashedSnapshot = snap
    }
  }

  /// Called from the shim on `prepareForRecycle`.
  @objc public func prepareForRecycle() {
    if registeredKey != nil {
      HeroRegistry.shared.unregister(self)
      registeredKey = nil
    }
    config = SharedHeroConfig()
    hiddenForFlight = false
    contentView.alpha = 1
    contentView.isHidden = false
    // Restore the shim's alpha in case a flight was interrupted before
    // `setHiddenForFlight`'s unhide branch ran (e.g. surface teardown
    // mid-flight); otherwise the next mount of this recycled instance starts
    // invisible.
    contentView.superview?.alpha = 1
    savedShimAlpha = 1
    stashedSnapshot = nil
    lastStableWindowFrame = .zero
    lastStableSettledFrame = .zero
  }

  /// Most recent window-space frame recorded while stably laid out and
  /// on-window (see `recordStableFrameSoon()`); the in-place flight's SOURCE
  /// rect. Deliberately NOT derived from a live capture at unregister time:
  /// during an in-place toggle Fabric moves the shim toward the NEW layout a
  /// beat before `contentView.bounds` catches up, so a capture there is torn
  /// (new origin + old size). Layout-metrics callbacks deliver a self-consistent
  /// frame, avoiding the tear.
  private(set) var lastStableWindowFrame: CGRect = .zero
  private(set) var lastStableSettledFrame: CGRect = .zero

  /// Called from the shim's `updateLayoutMetrics:oldLayoutMetrics:`. The
  /// registry uses it as an event-based trigger so a queued flight starts the
  /// instant Fabric applies the dest's frame — snappier than waiting for the
  /// poll loop to converge.
  @objc public func didUpdateLayoutMetrics() {
    HeroRegistry.shared.notifyLayoutReady(self)
    recordStableFrameSoon()
  }

  /// Records `lastStableWindowFrame` on the NEXT runloop tick, after Fabric's
  /// `layoutSubviews` propagates the new metrics to `contentView` (the metrics
  /// callback fires before that, so a synchronous read would be torn). Cheap:
  /// two `convert(_:to:)` reads, no bitmap capture, gated on being on-window.
  private func recordStableFrameSoon() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // Record even while `hiddenForFlight`: a hero hidden for an in-place
      // flight is still laid out at its real (new) position — only its pixels
      // are hidden — so `windowFrame()` is correct. We MUST capture it now
      // because no further `updateLayoutMetrics` may fire before the next
      // toggle, which would otherwise reuse the previous toggle's stale frame.
      guard self.contentView.window != nil else { return }
      let f = self.windowFrame()
      guard f != .zero else { return }
      self.lastStableWindowFrame = f
      let sf = self.settledWindowFrame()
      self.lastStableSettledFrame = sf != .zero ? sf : f
    }
  }

  /// Source snapshot for an in-place flight: the most recent rendered
  /// bitmap (stash) paired with the last STABLE geometry. The stash's own
  /// frame can be torn mid-toggle (see `lastStableWindowFrame`), so we
  /// override it with the layout-metrics-derived frame when we have one.
  func inPlaceBaselineSnapshot() -> HeroSnapshot? {
    guard let stash = captureOrCachedSnapshot() else { return nil }
    guard lastStableWindowFrame != .zero else { return stash }
    return HeroSnapshot(
      image: stash.image,
      frame: lastStableWindowFrame,
      settledFrame: lastStableSettledFrame != .zero ? lastStableSettledFrame : lastStableWindowFrame,
      cornerRadius: stash.cornerRadius,
      backgroundColor: stash.backgroundColor
    )
  }

  // MARK: - Event emission helpers, called from FlightEngine.

  func emitTransitionStart() {
    onTransitionStart?(config.heroId, config.heroNamespace)
  }

  func emitTransitionEnd() {
    onTransitionEnd?(config.heroId, config.heroNamespace)
  }

  // MARK: - Used by FlightEngine to compute the flight rect.

  /// This view's geometry in window coordinates, or `.zero` if off-window.
  /// Uses `convert(_:to:)`, so it REFLECTS in-progress ancestor transforms.
  /// For "where will this view LAND once the host transition completes?" (the
  /// flight engine's destination), use `settledWindowFrame()`.
  func windowFrame() -> CGRect {
    guard let window = contentView.window else { return .zero }
    return contentView.convert(contentView.bounds, to: window)
  }

  /// The window-space frame this view will occupy once any in-progress ancestor
  /// animations (push/pop transforms, sheet translations, etc.) finish.
  ///
  /// Implementation: snap every non-identity ancestor transform to identity
  /// inside a no-action `CATransaction`, read the frame via `convert(_:to:)`,
  /// then restore — all in one runloop tick so the "identity" state never
  /// renders.
  ///
  /// Why not walk the chain with `layer.position - anchor*size`? That works
  /// when a single ancestor carries the transform (a layer's MODEL position is
  /// invariant to its OWN transform), but FAILS when a wrapper ABOVE
  /// `screenView` (window → containerView → transitionView → screenView → …,
  /// e.g. an internal `UITransitionView`) is origin-shifted, or when stacked
  /// transforms drive the chain. Reset-and-convert is invariant to whatever the
  /// host does: all-identity ⇒ the visible rect IS the settled rect.
  ///
  /// Symptom fixed: on ArcPath the back-pop flight landed ~30% screen-width
  /// LEFT of the list's natural Visitor cell, matching `react-native-screens`'
  /// parallax shift on the re-entering screen. The layer-position walk resolved
  /// to that shifted rect, so `pollOnce`'s `matchesHint` fired on a stale hint
  /// and drove the overlay there instead of the natural cell.
  func settledWindowFrame() -> CGRect {
    guard let window = contentView.window else { return .zero }
    let bounds = contentView.bounds
    if bounds.width <= 0 || bounds.height <= 0 { return .zero }

    // Walk the `superlayer` chain (LAYERS, not views) for non-identity model
    // transforms, restored once we've read the rect. Layers matter: UIKit can
    // insert free-standing CALayers (custom backing layers, the CATransformLayer
    // some animator transitions use) that no UIView wraps, so `view.superview`
    // would skip them. RNS's simple_push sets the transform on the VC root view,
    // but the hosting `UITransitionView`'s layer chain can carry it at a node
    // the view chain never reaches (found via the ArcPath-push diagnostics).
    var savedTransforms: [(CALayer, CATransform3D)] = []
    var current: CALayer? = contentView.layer
    let windowLayer = window.layer
    while let l = current, l !== windowLayer {
      let t = l.transform
      if !CATransform3DIsIdentity(t) {
        savedTransforms.append((l, t))
      }
      current = l.superlayer
    }

    if savedTransforms.isEmpty {
      // No active transforms — `convert(_:to:)` already gives the answer.
      // Fast path keeps the common case (no transition in flight) zero-cost.
      return contentView.convert(bounds, to: window)
    }

    // Apply identity, read, restore inside a no-action transaction so no
    // implicit CAAnimation registers and no render-server flush lands between
    // the two `transform` writes. CoreAnimation commits the tree atomically at
    // tick end, so the "transforms reset" frame never shows.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (layer, _) in savedTransforms {
      layer.transform = CATransform3DIdentity
    }
    let result = contentView.convert(bounds, to: window)
    for (layer, t) in savedTransforms {
      layer.transform = t
    }
    CATransaction.commit()
    return result
  }

  /// This view's CURRENTLY-RENDERED window rect — the on-screen position
  /// reflecting any in-flight CAAnimation, read from the PRESENTATION layer
  /// rather than the model layer.
  ///
  /// Why it exists: when a UIKit transition COMMITS (an interactive swipe-back
  /// released, a sheet let go) the model tree jumps straight to its final value
  /// and only the presentation layers animate the remaining slide. `windowFrame()`
  /// (model, `convert(_:to:)`-based) therefore reports the destination instantly
  /// — gluing an overlay to it snaps. Reading the presentation layer instead lets
  /// the overlay track the real page motion frame-by-frame with no fixed
  /// duration/curve, on devices where the transition coordinator's signals are
  /// unreliable (iOS 18 + react-native-screens).
  ///
  /// `CALayer.convert(_:to:)` between two presentation layers composes the
  /// presentation (animated) geometry of every layer on the chain, so this is
  /// transform-correct the same way `settledWindowFrame()` is. Falls back to the
  /// model frame when no presentation layer exists yet (nothing animating).
  func presentationWindowFrame() -> CGRect {
    guard let window = contentView.window else { return .zero }
    let bounds = contentView.bounds
    if bounds.width <= 0 || bounds.height <= 0 { return .zero }
    guard let from = contentView.layer.presentation() else {
      return contentView.convert(bounds, to: window)
    }
    let to = window.layer.presentation() ?? window.layer
    return from.convert(bounds, to: to)
  }

  /// Diagnostic: one log line per ancestor layer (position / bounds / transform
  /// translation) to find which container causes an unexpected `windowFrame()`
  /// (e.g. a parallax-shifted result `settledWindowFrame()` should ignore).
  ///
  /// One line per ancestor, not one big string: the Apple System Log truncates
  /// above ~1 KB and the chain is 12+ levels deep on react-native-screens, so
  /// truncation would hide exactly the upper levels where host-navigator
  /// transforms live.
  func dumpLayerChain(prefix: String) {
    guard let window = contentView.window else {
      heroLog(HeroLog.chain, "\(prefix) view=\(ObjectIdentifier(self)) NO WINDOW")
      return
    }
    heroLog(HeroLog.chain, "\(prefix) view=\(ObjectIdentifier(self)) settled=\(settledWindowFrame()) visible=\(windowFrame()) ====")
    var layer: CALayer? = contentView.layer
    let windowLayer = window.layer
    var depth = 0
    while let l = layer, l !== windowLayer {
      let t = l.transform
      let isIdentity = CATransform3DIsIdentity(t)
      let viewCls = (l.delegate as? UIView).map { String(describing: type(of: $0)) } ?? "—"
      let layerCls = String(describing: type(of: l))
      heroLog(
        HeroLog.chain,
        "\(prefix) [\(depth)] view=\(viewCls) layer=\(layerCls) pos=(\(l.position.x.rounded()),\(l.position.y.rounded())) bnds=\(l.bounds) bnds.origin=(\(l.bounds.origin.x),\(l.bounds.origin.y)) tx=\(t.m41) ty=\(t.m42) m11=\(t.m11) m22=\(t.m22) identity=\(isIdentity)"
      )
      depth += 1
      layer = l.superlayer
    }
    heroLog(HeroLog.chain, "\(prefix) chain depth=\(depth) reachedWindow=\(layer === windowLayer)")
  }

  // MARK: - Flight visibility.

  /// Hides the in-place content while the overlay copy flies, so the source
  /// isn't seen sliding under it. Sets both `isHidden` AND `alpha` so a
  /// React-side opacity prop can't re-show it mid-flight.
  ///
  /// Hides BOTH `contentView` AND the shim (`contentView.superview`). React's
  /// style props (`backgroundColor`, `borderRadius`, shadow, …) land on the
  /// shim; `contentView` is just an empty wrapper for the Fabric children.
  /// Hiding only `contentView` leaves the shim's rounded `#eee` background
  /// drawing behind it — the "gray rounded rectangle at the source position"
  /// bug on BasicImageHero. `shim.alpha = 0` collapses the whole visual; we
  /// save the original alpha so a user `style={{ opacity }}` survives the
  /// round-trip.
  ///
  /// Caches a clean snapshot before hiding: `drawHierarchy` on a hidden /
  /// `alpha == 0` view renders empty, so a flight that starts while we're still
  /// hidden (tapping a new hero mid back-flight) would otherwise fly an
  /// invisible bitmap (a fade with no hero).
  private var hiddenForFlight = false
  private var savedShimAlpha: CGFloat = 1
  func setHiddenForFlight(_ hidden: Bool) {
    guard hiddenForFlight != hidden else { return }
    if hidden, let snap = captureSnapshotRaw() {
      stashedSnapshot = snap
    }
    hiddenForFlight = hidden
    contentView.isHidden = hidden
    contentView.alpha = hidden ? 0 : 1
    if let shim = contentView.superview {
      if hidden {
        savedShimAlpha = shim.alpha
        shim.alpha = 0
      } else {
        shim.alpha = savedShimAlpha
      }
    }
    heroLog(HeroLog.impl, "setHiddenForFlight=\(hidden) view=\(ObjectIdentifier(self)) contentSubviews=\(contentView.subviews.count) inWindow=\(contentView.window != nil) stashed=\(stashedSnapshot != nil)")
  }

  // MARK: - Snapshot capture.

  /// Cached snapshot taken in `setHiddenForFlight(true)` or
  /// `prepareToLeaveWindow()` so flights and the unregister back-flight path
  /// always have a usable source even when a live render would return empty.
  private var stashedSnapshot: HeroSnapshot?

  /// Literal render of the view's current state; `nil` if off-window or zero
  /// bounds. Use `captureSnapshot()` for the stash-aware version (falls back to
  /// the stash when a concurrent flight has us hidden).
  ///
  /// On success also REFRESHES `stashedSnapshot`, so later callers can degrade
  /// to "previous good content" when a fresh capture is impossible (briefly
  /// detached, mid-layout zero bounds) instead of dropping the flight.
  private func captureSnapshotRaw() -> HeroSnapshot? {
    guard contentView.window != nil else { return nil }
    let frame = windowFrame()
    if frame == .zero { return nil }

    let bounds = contentView.bounds
    if bounds.width <= 0 || bounds.height <= 0 { return nil }

    let renderer = UIGraphicsImageRenderer(bounds: bounds)
    let image = renderer.image { _ in
      contentView.drawHierarchy(in: bounds, afterScreenUpdates: false)
    }

    let snap = HeroSnapshot(
      image: image,
      frame: frame,
      settledFrame: settledWindowFrame(),
      cornerRadius: effectiveCornerRadius(),
      backgroundColor: effectiveBackgroundColor()
    )
    stashedSnapshot = snap
    return snap
  }

  /// Corner radius used to clip the flight overlay so it matches the source.
  ///
  /// React applies `borderRadius` / `overflow: 'hidden'` to the Fabric host —
  /// the `SharedHeroView` shim (superview of `contentView`) — so `contentView`
  /// itself is never rounded for the common `<SharedHero style={{ borderRadius
  /// }}>` pattern. The old lookup only checked `contentView` + its first child,
  /// resolving to 0, so `runLinearFlight` skipped its `CABasicAnimation` and the
  /// overlay flew square from t=0 ("border radius removed before the flight").
  ///
  /// Resolution order:
  /// 1. `contentView.layer.cornerRadius` — radius set directly on the impl view
  ///    (rare; for symmetry).
  /// 2. `contentView.superview.layer.cornerRadius` — the SHIM, where React's
  ///    `borderRadius` actually lands.
  /// 3. `contentView.subviews.first?.layer.cornerRadius` — user wrapped an inner
  ///    View with the radius instead.
  @objc public func effectiveCornerRadius() -> CGFloat {
    let direct = contentView.layer.cornerRadius
    if direct > 0 { return direct }
    if let shim = contentView.superview {
      let shimRadius = shim.layer.cornerRadius
      if shimRadius > 0 { return shimRadius }
    }
    if let firstChild = contentView.subviews.first {
      return firstChild.layer.cornerRadius
    }
    return 0
  }

  /// Mirror of `effectiveCornerRadius()` for `backgroundColor`, used by
  /// morph-mode flights to crossfade source tint into dest. Same rationale:
  /// `<SharedHero style={{ backgroundColor }}>` lands on the shim, not
  /// `contentView`.
  @objc public func effectiveBackgroundColor() -> UIColor {
    if let bg = contentView.backgroundColor, bg.cgColor.alpha > 0 {
      return bg
    }
    if let bg = contentView.superview?.backgroundColor, bg.cgColor.alpha > 0 {
      return bg
    }
    if let bg = contentView.subviews.first?.backgroundColor, bg.cgColor.alpha > 0 {
      return bg
    }
    return .clear
  }

  /// Snapshot of this view's content for use as a flight source.
  ///
  /// Resolution order:
  /// 1. If hidden by another flight, return the pre-hide stash —
  ///    `drawHierarchy` on a hidden view renders empty.
  /// 2. A fresh render via `captureSnapshotRaw()`.
  /// 3. Fall back to `stashedSnapshot` if the live render failed. Safety net for
  ///    the "no flight at all" regression: when `runTwinFlight` asked the instant
  ///    a re-attached list hero hadn't committed layout, the live render returned
  ///    nil and the whole forward flight dropped (screen just faded). The stash
  ///    flies the last known content instead (right position/bitmap, a few ms
  ///    stale).
  func captureSnapshot() -> HeroSnapshot? {
    if hiddenForFlight, let stash = stashedSnapshot {
      return stash
    }
    if let fresh = captureSnapshotRaw() {
      return fresh
    }
    if let stash = stashedSnapshot {
      heroLog(HeroLog.impl, "captureSnapshot falling back to stash view=\(ObjectIdentifier(self)) inWindow=\(contentView.window != nil) bounds=\(contentView.bounds)")
      return stash
    }
    heroLog(HeroLog.impl, "captureSnapshot returned nil (no live & no stash) view=\(ObjectIdentifier(self)) inWindow=\(contentView.window != nil) bounds=\(contentView.bounds)")
    return nil
  }

  /// Returns a fresh snapshot if the view is still in the window, otherwise
  /// the most recent stashed snapshot. Used by the registry on the unregister
  /// path so the back-flight can still fire when the source view has already
  /// left the window.
  func captureOrCachedSnapshot() -> HeroSnapshot? {
    return captureSnapshot() ?? stashedSnapshot
  }
}

/// Immutable capture of a `SharedHeroViewImpl`'s appearance and geometry.
///
/// `frame` is the LIVE window rect (reflects in-progress ancestor transforms):
/// the flight's START rect, so a back-flight after a drag-to-dismiss starts at
/// the dragged position, not the natural one.
///
/// `settledFrame` is the window rect WITHOUT ancestor transforms (via
/// `settledWindowFrame()`): the registry's `destFrameHint` cache, so a future
/// push lands at the natural position, not the previous pop's transformed one.
/// Without the split, "drag to dismiss, then re-tap" cached the dragged rect as
/// the hint and pollOnce landed the next flight wrong or waited out its 2 s
/// timeout (dest invisible throughout — "drag stopped working / detail blank").
struct HeroSnapshot {
  let image: UIImage?
  let frame: CGRect
  let settledFrame: CGRect
  let cornerRadius: CGFloat
  let backgroundColor: UIColor
}
