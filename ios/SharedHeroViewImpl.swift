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
  /// When false, this hero performs a quiet teardown on unregister: it never
  /// initiates a return/back-flight. Defaults to true (today's behaviour).
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

  /// Set by the shim — invoked with `(id, namespace)` when the source view's
  /// outbound flight starts.
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
      // Intentionally DO NOT wipe `stashedSnapshot` here. Previously we
      // cleared it on re-attach, but that left a window of fragility: if
      // the very next forward flight asked for a snapshot before Fabric had
      // committed our first layout (window is non-nil but `bounds == .zero`
      // for one tick) `captureSnapshotRaw()` would return nil, the stash
      // would be nil too, and `HeroRegistry.runTwinFlight` would abort with
      // no flight. The user-visible symptom was "detail page fades in
      // without the hero animation", repeatable after a few back-button
      // round-trips because the symptom only manifests on the first tap
      // after a re-attach. Keeping the most recent successful capture
      // around as a worst-case fallback lets the flight still fire (with
      // slightly stale source content, which is invisible during the very
      // first frames of a flight anyway). The stash is naturally refreshed
      // by every subsequent `captureSnapshotRaw()` call.
      if registeredKey == nil {
        HeroRegistry.shared.register(self)
        registeredKey = "\(config.heroNamespace)::\(config.heroId)"
      }
      // Record the stable frame on attach too — on the INITIAL mount the
      // sole `updateLayoutMetrics` fires before we're on-window, so the
      // recorder scheduled there bails (window == nil) and never runs
      // again, leaving `lastStableWindowFrame == .zero` for the first
      // in-place toggle (which then falls back to the torn live capture
      // and starts the flight 100pt off). Triggering here guarantees a
      // valid stable frame is captured once we're actually on-window.
      recordStableFrameSoon()
      // For a recycled in-place view, Fabric applies the NEW layout BEFORE
      // re-attaching us to the window (the `updateLayoutMetrics` that set
      // the new size fired while `window == nil`, so the trigger there
      // bailed). Attaching is therefore the first on-window moment the
      // resize is visible — give the registry a synchronous chance to
      // detect it and hide+fly in THIS transaction, before the new state
      // renders uncovered (the "tap → flash new size → rewind → animate"
      // glitch). `notifyLayoutReady` no-ops unless we're being watched for
      // an in-place resize AND the SIZE actually changed.
      HeroRegistry.shared.notifyLayoutReady(self)
    } else if window == nil {
      if registeredKey != nil {
        HeroRegistry.shared.unregister(self)
        registeredKey = nil
      }
    }
  }

  /// Called from the shim's `willMoveToWindow:` when the view is about to be
  /// removed from its current window. Captures and stashes the snapshot while
  /// the view is still in the window so the back-flight has a valid source
  /// frame even if the navigator's mount/unmount order causes us to lose the
  /// twin-register match (e.g. the destination hero re-attaches AFTER the
  /// source unmounts — by which point `captureSnapshot` would otherwise see
  /// `contentView.window == nil` and return `nil`).
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
    // Restore the shim's alpha in case a flight was interrupted before the
    // unhide branch in `setHiddenForFlight` ran (e.g. surface teardown
    // mid-flight). Without this the next mount of a recycled view
    // instance would start invisible.
    contentView.superview?.alpha = 1
    savedShimAlpha = 1
    stashedSnapshot = nil
    lastStableWindowFrame = .zero
    lastStableSettledFrame = .zero
  }

  /// Most recent window-space frame recorded while the view was stably
  /// laid out and on-window — see `recordStableFrameSoon()`. Used as the
  /// in-place flight's SOURCE rect. We deliberately do NOT derive this
  /// from a live `captureSnapshotRaw()` at unregister time: during an
  /// in-place toggle Fabric repositions the shim toward the NEW layout
  /// (e.g. the 320pt origin) a beat before `contentView.bounds` catches
  /// up, so a capture in that window yields a torn frame (new origin +
  /// old size). Layout-metrics callbacks always deliver a self-consistent
  /// frame, so recording from there avoids the tear.
  private(set) var lastStableWindowFrame: CGRect = .zero
  private(set) var lastStableSettledFrame: CGRect = .zero

  /// Called from the shim's `updateLayoutMetrics:oldLayoutMetrics:`. The
  /// registry uses this as an event-based trigger so a queued flight starts
  /// the instant Fabric has applied the destination's frame — much snappier
  /// than waiting for our polling loop to converge.
  @objc public func didUpdateLayoutMetrics() {
    HeroRegistry.shared.notifyLayoutReady(self)
    recordStableFrameSoon()
  }

  /// Records `lastStableWindowFrame` on the NEXT runloop tick, after
  /// Fabric's `layoutSubviews` has propagated the new metrics down to
  /// `contentView` (the metrics callback fires before that, so reading
  /// the frame synchronously here would itself be torn). Cheap: just two
  /// `convert(_:to:)` reads, no bitmap capture, gated on the view being
  /// on-window and not mid-flight.
  private func recordStableFrameSoon() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // Record even while `hiddenForFlight`: a hero hidden for an in-place
      // flight is still laid out at its real (new) position — only its
      // pixels are hidden — so `windowFrame()` is correct and we MUST
      // capture it here, because after the flight no further
      // `updateLayoutMetrics` may fire to refresh it before the next
      // toggle (which would otherwise reuse the previous toggle's stale
      // frame as the in-place source rect).
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

  /// Snapshot of this view's geometry in window coordinates. Falls back to
  /// `.zero` if not currently in a window.
  ///
  /// Note: this uses `convert(_:to:)` which reflects any in-progress transform
  /// animations on ancestor views. For the "where will this view LAND once
  /// the host navigator's transition completes?" question (which is what the
  /// flight engine needs for the destination), use `settledWindowFrame()`.
  func windowFrame() -> CGRect {
    guard let window = contentView.window else { return .zero }
    return contentView.convert(contentView.bounds, to: window)
  }

  /// The window-space frame this view will occupy once any in-progress
  /// ancestor animations (push/pop transition transforms, modal sheet
  /// translations, etc.) finish.
  ///
  /// Implementation: collect every ancestor whose layer has a non-identity
  /// transform, snap them all to identity inside a no-action
  /// `CATransaction`, read the window frame via the standard
  /// `convert(_:to:)`, then restore every transform — all in one runloop
  /// tick so the screen never renders the intermediate "identity"
  /// state.
  ///
  /// Why not just walk the layer chain with `layer.position - anchor*size`?
  /// That works for the simple case where a single ancestor (the screen
  /// container) carries the transform, because the layer's MODEL position
  /// is invariant to its OWN transform. But it FAILS the moment a host
  /// navigator stack uses a chain like:
  ///
  ///     window → containerView → transitionView → screenView → ...
  ///
  /// and one of the wrappers ABOVE `screenView` (e.g. an internal UIKit
  /// `UITransitionView`) has its origin shifted as part of the animation,
  /// or when an outer animator drives the chain with multiple stacked
  /// transforms. The reset-and-convert path is invariant to whatever the
  /// host does internally — if every transform is identity, the visible
  /// rect IS the settled rect by definition.
  ///
  /// Symptom this is fixing: on ArcPath the back-pop's flight lands ~30%
  /// of the screen width LEFT of the LIST's natural Visitor cell, which
  /// matches `react-native-screens`' parallax shift on the pop's
  /// re-entering screen. The layer-position walk above resolved to that
  /// same shifted rect, so `pollOnce`'s `matchesHint` check fired with a
  /// stale (parallax-shifted) hint and the flight engine drove the
  /// overlay there instead of the natural list cell.
  func settledWindowFrame() -> CGRect {
    guard let window = contentView.window else { return .zero }
    let bounds = contentView.bounds
    if bounds.width <= 0 || bounds.height <= 0 { return .zero }

    // Collect every ancestor LAYER (not just UIView ancestor — we walk
    // the layer's `superlayer` chain) that currently has a non-identity
    // model transform. We restore these as soon as we've read the rect.
    //
    // Walking layers, not views, is important: UIKit can insert
    // free-standing CALayers in between (custom backing layers, the
    // CATransformLayer used by some animator transitions, etc.) that
    // are NOT wrapped by a UIView, and `view.superview` would skip
    // straight past them. `react-native-screens`' simple_push animation
    // sets the transform on the view controller's root view, but the
    // hosting `UITransitionView`'s layer chain can resolve the
    // transform at a different node than the one we'd reach via the
    // view chain — we discovered this exactly via the
    // ArcPath-push diagnostic logs.
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
      // No active transforms — `convert(_:to:)` already gives the answer
      // we want. Fast path keeps the common case (no host-navigator
      // transition in flight) zero-cost.
      return contentView.convert(bounds, to: window)
    }

    // Apply identity, read, restore — all inside a no-action transaction
    // so no implicit CAAnimation is registered and no render-server flush
    // happens between the two `transform` writes. CoreAnimation commits
    // the layer tree atomically at the end of the runloop tick, so the
    // user never sees the "transforms reset" frame.
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

  /// Diagnostic logger: emits ONE log line per ancestor in the layer chain
  /// with its position / bounds / transform translation. Useful for
  /// figuring out which container is responsible for an unexpected
  /// `windowFrame()` value (e.g. a parallax-shifted result that
  /// `settledWindowFrame()` should be ignoring).
  ///
  /// We emit one log line per ancestor rather than one big multi-line string
  /// because the Apple System Log truncates payloads above ~1 KB, and the
  /// chain is typically 12+ levels deep on react-native-screens — the
  /// truncation hides exactly the upper levels where host-navigator
  /// transforms live, defeating the whole point of dumping the chain.
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

  /// Hides the in-place content while the flying overlay copy is animating so
  /// the user doesn't see the source view sliding under the overlay. We set
  /// both `isHidden` (the sledgehammer) and `alpha` so the React-side opacity
  /// prop can't accidentally re-show the content mid-flight.
  ///
  /// We hide BOTH `contentView` AND the shim (`contentView.superview`, our
  /// `RCTViewComponentView` host). React's style props
  /// (`backgroundColor`, `borderRadius`, `borderWidth`, shadow, …) all land
  /// on the shim — `contentView` is just an empty UIView wrapper that
  /// hosts the Fabric-mounted children. Hiding only `contentView` leaves
  /// the shim's rounded `#eee` background drawing behind the now-empty
  /// contentView for the entire flight, which is exactly the "gray
  /// rounded rectangle at the source position" bug reported on
  /// BasicImageHero. Setting `shim.alpha = 0` collapses the whole visual
  /// for the duration of the flight; we save the original alpha so a
  /// user-applied `<SharedHero style={{ opacity: ... }}>` survives the
  /// flight round-trip.
  ///
  /// Before transitioning to `hidden = true` we cache a clean snapshot —
  /// `drawHierarchy` on an `isHidden` (or `alpha == 0`) view returns empty
  /// pixels, so without this any flight that starts while we're still hidden
  /// (e.g. user taps a new hero while the back-flight is still running)
  /// would fly an invisible bitmap and the user would just see a fade with
  /// no hero.
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

  /// Literal render of the view's current state. Returns `nil` if the view
  /// has no window or zero bounds. Use `captureSnapshot()` for callers that
  /// want the stash-aware version (which falls back to the stash when the
  /// view is currently hidden by a concurrent flight).
  ///
  /// On success this also REFRESHES `stashedSnapshot`. The stash therefore
  /// always reflects the most recent successful capture, which lets later
  /// callers gracefully degrade to "previous good content" when a fresh
  /// capture isn't possible (view briefly detached, mid-layout zero bounds,
  /// etc.) instead of dropping the flight entirely.
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

  /// Resolves the corner radius that should be used to clip the flight
  /// overlay so it visually matches the source view.
  ///
  /// React applies `borderRadius` (and `overflow: 'hidden'`) to the Fabric
  /// host view — i.e. the Obj-C++ `SharedHeroView` shim, which is the
  /// **superview** of `contentView`. `contentView` itself never has a
  /// non-zero `cornerRadius` for the common usage pattern:
  ///
  ///     <SharedHero style={{ borderRadius: 16, overflow: 'hidden' }}>
  ///       <Image ... />
  ///     </SharedHero>
  ///
  /// The old lookup chain only inspected `contentView` and
  /// `contentView.subviews.first` (the Fabric-mounted children), so it
  /// resolved to 0 every time. With `initial.cornerRadius = 0`,
  /// `FlightEngine.runLinearFlight` skipped its `CABasicAnimation`, the
  /// `flightView` was created with `cornerRadius = 0`, and the overlay
  /// flew as a square from t=0 — visible as "border radius removed
  /// before the flight starts".
  ///
  /// Resolution order:
  /// 1. `contentView.layer.cornerRadius` — covers anyone who explicitly
  ///    set the radius on the impl view (rare; here for symmetry).
  /// 2. `contentView.superview.layer.cornerRadius` — the SHIM, which is
  ///    where the React `borderRadius` style actually lands.
  /// 3. `contentView.subviews.first?.layer.cornerRadius` — the rare case
  ///    where the user wraps an inner View with the radius instead.
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
  /// morph-mode flights to crossfade the source's background tint into
  /// the destination's. Same rationale: `<SharedHero style={{
  /// backgroundColor: ... }}>` lands on the shim, not on `contentView`.
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

  /// Captures the current snapshot of this view's content for use as the
  /// source of a flight.
  ///
  /// Resolution order:
  /// 1. If the view is currently hidden by another flight, return the pre-
  ///    hide stash — `drawHierarchy` on a hidden view renders empty pixels.
  /// 2. Try a fresh render via `captureSnapshotRaw()`.
  /// 3. Fall back to `stashedSnapshot` (the most recent successful capture)
  ///    if the live render couldn't produce one. This is the safety net
  ///    that catches the "no flight at all" regression after several
  ///    back-button cycles: when `runTwinFlight` asked for a snapshot the
  ///    instant a list-screen hero had been re-attached but Fabric hadn't
  ///    committed its layout yet, the live render returned nil. Without
  ///    this fallback the entire forward flight would silently drop and
  ///    the user just saw the screen fade. With it, we fly the previous
  ///    known content (correct position and bitmap; only a few ms stale).
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
/// `frame` is the live window-space rect (via `convert(_:to:window)`), which
/// REFLECTS any in-progress transforms on this view's ancestors — used as the
/// flight's START rect so a back-flight after a drag-to-dismiss starts at the
/// dragged position, not the natural layout position.
///
/// `settledFrame` is the window-space rect WITHOUT ancestor transforms
/// (via `settledWindowFrame()`) — used by the registry's `destFrameHint`
/// cache so a future push can land at the natural layout position, not the
/// previous pop's transformed position. Without this split the
/// "drag down to dismiss, then tap the same hero again" path stashed the
/// dragged rect as the cached hint and pollOnce would either land the next
/// forward flight at the wrong rect or wait out its 2 s timeout (the
/// destination stays invisible the whole time, which the user perceives as
/// "drag stopped working / detail is blank").
struct HeroSnapshot {
  let image: UIImage?
  let frame: CGRect
  let settledFrame: CGRect
  let cornerRadius: CGFloat
  let backgroundColor: UIColor
}
