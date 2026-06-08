import Foundation
import QuartzCore
import UIKit

/// Process-wide registry of currently-mounted `SharedHeroViewImpl`s. Drives
/// the router-agnostic match logic.
///
/// Two trigger paths exist:
///
/// 1. **Twin appears while another is still live** — handles native-stack
///    push and pop, where both the previous and next screens' hero views are
///    attached to the window during the navigation animation. We capture the
///    existing twin's snapshot the moment the new twin registers, so the
///    source frame is recorded *before* the navigator starts moving it, and
///    schedule the flight on the next runloop tick when the new twin has
///    been laid out.
///
/// 2. **Existing twin unregisters, then a new one mounts within one tick** —
///    handles state-driven in-place transitions where one hero is unmounted
///    and immediately replaced by a sibling with the same id.
///
/// Main-thread only.
@objc public final class HeroRegistry: NSObject {
  @objc public static let shared = HeroRegistry()

  /// Currently-mounted views, keyed by `(namespace, id)`.
  private var live: [String: [WeakBox]] = [:]

  /// Views that unregistered during the current matching window, kept as
  /// source candidates for one runloop tick.
  ///
  /// We store the source view's `ObjectIdentifier` alongside the snap so
  /// `runMatchPass` can detect "the new dest is the SAME view instance
  /// that just unregistered" — a host-navigator reparent churn that
  /// slipped past the `pendingUnregisters` defer (e.g. unregister
  /// committed in tick N, register fired in tick N+1). Firing a flight
  /// from a view to itself produces a phantom snapshot of an unrelated
  /// list image floating above the destination screen, which is the
  /// reported ArcPath ghost-image bug.
  private struct RecentlyUnregisteredEntry {
    let snap: HeroSnapshot
    let sourceViewId: ObjectIdentifier
  }
  private var recentlyUnregistered: [String: RecentlyUnregisteredEntry] = [:]

  /// Keys whose state changed this tick and that should be re-evaluated.
  private var pendingKeys: Set<String> = []

  /// `ObjectIdentifier`s of views that already played the source of a recent
  /// twin-flight, so we skip the in-place match path when they later
  /// unregister with a stale snapshot.
  private var alreadyFlighted: Set<ObjectIdentifier> = []

  /// Last successful source-side snapshot we captured for each
  /// `(namespace, id)` key. Populated in two places only:
  ///   * `runTwinFlight(source:dest:)` when the source's live capture
  ///     succeeds — captures the canonical list-side snap on every forward
  ///     push.
  ///   * `unregister(_:)` when the unregistering view was the source of a
  ///     recent forward flight (the `alreadyFlighted` branch) — captures the
  ///     source-side snap one more time before the host screen tears it
  ///     down, so the next forward push has something to fall back to.
  ///
  /// Intentionally NOT populated when a destination-side view (e.g. a detail
  /// hero being dismissed) unregisters. Mixing those snaps into the same
  /// key would make a later forward flight render from the destination's
  /// bitmap and frame — the user would see "no flight" again.
  ///
  /// This is the registry-level safety net for the symptom "tap A → back →
  /// tap A → ... after a few cycles, detail page fades in without the hero
  /// flight". The view's own `stashedSnapshot` covers the common case where
  /// the source view is still around but its live render returns empty (mid
  /// layout, briefly off-window, etc.). This per-key cache also covers the
  /// case where the source view has been recycled or temporarily torn down
  /// by Fabric / react-native-screens between two pushes, so even the view-
  /// level stash is gone.
  private var lastKnownSnapshots: [String: HeroSnapshot] = [:]

  /// Window-frame of the most recent flight's *source* per key. Updated
  /// EVERY time a flight is queued — both forward (runTwinFlight, source =
  /// list) and back (unregister-twin or re-register runTwinFlight, source =
  /// detail). Read in the NEXT flight as `destFrameHint`, exploiting the
  /// push/pop symmetry:
  ///
  ///   push #1: src=list,   dest=detail → record list.frame
  ///   pop  #1: src=detail, dest=list   → hint = list.frame  (✓ matches dest)
  ///                                     → record detail.frame
  ///   push #2: src=list,   dest=detail → hint = detail.frame (✓ matches dest)
  ///                                     → record list.frame
  ///   ...
  ///
  /// Kept SEPARATE from `lastKnownSnapshots` so the destination-side
  /// (detail) frame can be cached for symmetry without polluting the
  /// source-fallback bitmap cache.
  private var lastFlightSourceFrame: [String: CGRect] = [:]

  /// Flights queued waiting for the destination's first stable layout. Keyed
  /// by the destination view's identity. Consumed by the polling chain in
  /// `pollOnce(_:)`; first stable sample wins.
  private struct PendingFlight {
    let snap: HeroSnapshot
    weak var source: SharedHeroViewImpl?
    /// Previous tick's settled frame for this dest. We only fire when two
    /// consecutive polls (each in its own runloop tick) read the same value,
    /// so we don't land at a stale position while Fabric is still committing
    /// the re-attached subtree's layout.
    var lastSampledFrame: CGRect?
    /// Last-known stable frame for this key, captured at a previous
    /// quiescent moment (typically the previous flight's source side — the
    /// hero that lived at this position before any navigator started moving
    /// things around). When present, `pollOnce` waits for `settled` to
    /// converge to this rect (within tolerance) before firing, rather than
    /// trusting two consecutive identical `settled` samples that could
    /// agree on a transient WRONG layout.
    ///
    /// The motivating bug: on an interactive iOS pop, `react-native-screens`
    /// re-attaches the previous screen to the window at gesture start and
    /// Fabric needs to re-apply layout metrics to the whole subtree. For one
    /// or two runloop ticks the chain can resolve to a position that's off
    /// by the inner-container padding (a typical 16pt left shift) before
    /// converging to the real value. The legacy two-tick check fires on the
    /// transient pair and the back-flight lands at the wrong rect.
    var destFrameHint: CGRect?
    var attemptsLeft: Int
    /// Has the destination view ever been on a window since this flight was
    /// queued? A destination can register (and fire `runTwinFlight`) from
    /// `updateProps`/`didUpdateConfig` BEFORE it is attached to a window —
    /// and a UIKit modal (react-native-screens `presentation: 'modal'` /
    /// `'transparentModal'`) keeps its presented content OFF-WINDOW until
    /// the present animation finishes. Until the first attach we must not
    /// burn `attemptsLeft` (the layout-settle budget), otherwise the poll
    /// gives up before the modal even attaches the hero and the flight is
    /// silently dropped (the reported "modal opens, no flight" bug).
    var everAttached: Bool = false
    /// Wall-clock deadline for the FIRST attach. Bounds the pre-attach wait
    /// so a flight queued for a destination that is torn down before it
    /// ever attaches still unhides instead of staying hidden forever. Uses
    /// wall-clock (not a tick count) because `schedulePoll` hops via
    /// `DispatchQueue.main.async` back-to-back when idle — 120 hops can
    /// elapse in a fraction of the modal present's duration.
    var attachDeadline: CFTimeInterval?
  }
  private var pendingFlights: [ObjectIdentifier: PendingFlight] = [:]

  /// Destinations with an *active* flight (between fire and completion). We
  /// refuse to start a second flight for a dest while one is still running,
  /// which catches any duplicate-trigger code path (e.g. host navigator
  /// re-emitting register/layout events mid-transition).
  private var currentlyFlying: Set<ObjectIdentifier> = []

  /// Unregister calls that are PENDING — i.e. the view called
  /// `didMoveToWindow(nil)` and we haven't yet committed the unregister
  /// side-effects (capturing the snap, firing back-flights, scheduling a
  /// match-pass). We defer the commit to the next runloop tick so that
  /// if the SAME view re-registers in the same tick (because the host
  /// navigator briefly reparented our subtree without truly unmounting
  /// it — `react-native-screens` does this on every push to move the
  /// from-screen into the transition container view), we cancel the
  /// commit and treat the whole thing as a no-op.
  ///
  /// Symptom this is fixing: on an ArcPath forward push, every LIST
  /// hero (Pine / Glacial / Summit / Visitor) goes window=false →
  /// window=true within ~one runloop tick. Without churn detection the
  /// registry sees that as four genuine unmount/remount cycles and:
  ///   1) fires three bogus match-pass flights for Pine/Glacial/Summit
  ///      (they unregister with no live twin → schedule match-pass;
  ///      they re-register → match-pass picks them up as both source
  ///      and dest), polluting the screen with three flying snapshots
  ///      of unrelated images during the navigation;
  ///   2) clears `alreadyFlighted[LIST.visitor]` via the register-side
  ///      cleanup, so when LIST.visitor truly unregisters at end of
  ///      push, the alreadyFlighted guard misses and the unregister-
  ///      twin fast path fires a bogus SECOND flight from LIST.visitor
  ///      to DETAIL.visitor — the user sees the hero "fly twice".
  ///
  /// Keyed by ObjectIdentifier (the view's memory address) because the
  /// SAME view instance returns through register; Fabric does not
  /// allocate a new component view for a reparent.
  private struct PendingUnregister {
    let view: SharedHeroViewImpl
    let key: String
    /// Appearance + geometry captured at unregister time, while the view's
    /// stash is still valid. We CANNOT recapture this later in the
    /// churn-cancel branch: when Fabric recycles the component (the
    /// InPlaceToggle case) it nils the view's `stashedSnapshot` between
    /// `unregister` and the recycled `register`, so a capture there
    /// returns nil. Grabbing it here — right after `didMoveToWindow(nil)`,
    /// when `prepareToLeaveWindow` has just refreshed the stash — is the
    /// last moment the old appearance is reliably available.
    let baseline: HeroSnapshot?
    /// Captured at unregister time because the view's `config` may be reset
    /// (e.g. `prepareForRecycle`) before this deferred commit runs. When
    /// false, `commitUnregister` skips the back-flight entirely.
    let returnFlightEnabled: Bool
  }
  private var pendingUnregisters: [ObjectIdentifier: PendingUnregister] = [:]

  /// Views that hit the `register` churn-cancel branch (same view + same
  /// key re-registered within a tick) and might be an IN-PLACE transition
  /// rather than a host-navigator reparent. We can't tell which at
  /// register time because Fabric hasn't applied the new layout metrics
  /// yet — both a reparent and an in-place toggle look identical (same
  /// `ObjectIdentifier`, same key, momentarily-unchanged bounds).
  ///
  /// So we stash the PRE-churn appearance as a baseline and poll the
  /// view's settled frame:
  ///   • settles at a DIFFERENT rect (size or position) → genuine
  ///     in-place transition (e.g. the InPlaceToggle example, where one
  ///     `SharedHero id="hero-inplace"` swaps a 120pt style for a 320pt
  ///     style and Fabric RECYCLES the same component view) → fire a
  ///     self-flight from the baseline rect to the new rect.
  ///   • settles UNCHANGED within the attempt budget → it was a host
  ///     navigator reparent (ArcPath push reparents every LIST hero
  ///     through the transition container without changing its layout)
  ///     → discard the baseline, no flight.
  private struct PendingInPlace {
    let baseline: HeroSnapshot
    var attemptsLeft: Int
  }
  private var pendingInPlace: [ObjectIdentifier: PendingInPlace] = [:]

  /// How many runloop ticks we wait for a churn-cancelled view to settle
  /// at a new frame before concluding it was a reparent (no resize). The
  /// in-place toggle applies its new layout within ~1–2 ticks of
  /// re-register, so this is generous; a reparent just wastes this many
  /// cheap geometry reads then discards.
  private let inPlaceMaxAttempts: Int = 12

  /// Minimum delta (points) in size or origin for a churn-cancelled
  /// view's new settled frame to count as a genuine in-place transition
  /// rather than layout jitter / a transform-free reparent.
  private let inPlaceChangeThreshold: CGFloat = 6

  private var matchScheduled = false

  private override init() {
    super.init()
  }

  // MARK: - Public API

  func register(_ view: SharedHeroViewImpl) {
    // Pre-warm the overlay UIWindow on the very first hero registration.
    // Creating it here (rather than lazily inside `FlightEngine.run`) gives
    // it time to render its first (empty, transparent) frame on a separate
    // window render-server flush before any flight actually adds a subview.
    // Without this, the user's first tap-to-fly can show a one-frame white
    // flash at the source position while the overlay window is still
    // performing its initial display pass.
    OverlayHost.shared.prepare()

    let viewId = ObjectIdentifier(view)

    // CHURN CANCEL: this view called didMoveToWindow(nil) earlier in this
    // (or the previous) runloop tick and we deferred the unregister
    // commit. If the SAME view + SAME key has now reattached, the host
    // navigator just reparented us (not really unmounted us). Cancel the
    // pending commit and keep ALL existing registry state — bucket
    // membership, `alreadyFlighted` / `currentlyFlying` / `pendingFlights`
    // entries, everything. If we instead let the unregister commit run
    // and then ran the rest of `register` here, we'd:
    //   - generate a bogus match-pass flight (the view appears in both
    //     `recentlyUnregistered` and `pendingKeys` for the same key);
    //   - clear `alreadyFlighted[self]`, making the genuine end-of-push
    //     unregister fire the unregister-twin back-flight bug.
    // The view is still in `live[key]` because we never committed the
    // unregister, so there's literally nothing else to do.
    //
    // KEY-CHANGED branch: if the view is in `pendingUnregisters` but its
    // current key differs, Fabric has recycled this view instance for a
    // different component (Fabric reuses RCTViewComponentView instances
    // across mounts; `prepareForRecycle` calls `unregister(self)` with
    // the OLD key, then `updateProps` immediately mounts a new component
    // and calls `register(self)` with the NEW key). We must commit the
    // pending unregister NOW (for the old key, with the old hero state),
    // then fall through to the regular register for the new key. Without
    // this branch we'd churn-cancel across hero ids and leave the old
    // key's bucket entry dangling.
    let currentKey = Self.key(for: view)
    if let pending = pendingUnregisters[viewId] {
      if pending.key == currentKey {
        pendingUnregisters.removeValue(forKey: viewId)
        // This is EITHER a host-navigator reparent (no SIZE change →
        // genuinely cancel) OR a Fabric-recycled in-place transition
        // (size changes → should fly). We can't decide here because the
        // new layout metrics aren't applied yet, so we stash the baseline
        // captured at unregister time. The decision (and the flight) is
        // then made by `notifyLayoutReady(_:)` synchronously the instant
        // the new layout/attach arrives — with `pollInPlace` as an async
        // fallback. Both key off a SIZE change only (position alone is NOT
        // enough — an RNS push parallax-shifts a sibling's origin
        // transiently, which must not be mistaken for an in-place move).
        // If a flight is already running, or we already queued a baseline,
        // leave it be.
        if pendingInPlace[viewId] == nil,
           !currentlyFlying.contains(viewId),
           let baseline = pending.baseline,
           baseline.settledFrame != .zero {
          pendingInPlace[viewId] = PendingInPlace(baseline: baseline, attemptsLeft: inPlaceMaxAttempts)
          NSLog("[SharedHeroRegistry] register CHURN-CANCEL view=\(Self.id(view)) key=\(currentKey) — watching for in-place resize baseline=\(baseline.settledFrame)")
          scheduleInPlaceCheck(view: view)
        } else {
          NSLog("[SharedHeroRegistry] register CHURN-CANCEL view=\(Self.id(view)) key=\(currentKey) — host navigator reparented, preserving state")
        }
        return
      } else {
        NSLog("[SharedHeroRegistry] register key-changed during defer view=\(Self.id(view)) oldKey=\(pending.key) newKey=\(currentKey) — committing old unregister inline")
        pendingUnregisters.removeValue(forKey: viewId)
        commitUnregister(view: pending.view, key: pending.key, baseline: pending.baseline, returnFlightEnabled: pending.returnFlightEnabled)
        // Fall through to regular register for the new key.
      }
    }

    // ObjectIdentifier is just the view's memory address. Fabric recycles
    // RCTViewComponentView instances, and once a previously-recycled view
    // is dealloc'd, that address can be reused for a freshly-allocated
    // component. The new instance is logically a brand-new view but shares
    // an ObjectIdentifier with the dead one — so any state in
    // `currentlyFlying` / `alreadyFlighted` / `pendingFlights` keyed by
    // that id is stale, belongs to the dead view, and must be cleared.
    //
    // Symptom if we don't: after a few tap→back→tap cycles, the
    // `currentlyFlying` entry from a previous flight (whose `dest` was
    // dealloc'd before `onAllDone` could remove it) survives, and the
    // duplicate-suppression branch in `pollOnce` aborts the new flight.
    // User sees just a fade with no hero, indefinitely.
    //
    // (Note: this runs AFTER the churn-cancel check above, so a genuine
    // reparent does NOT clear these — only true new-view registrations.)
    currentlyFlying.remove(viewId)
    alreadyFlighted.remove(viewId)
    pendingFlights.removeValue(forKey: viewId)
    pendingInPlace.removeValue(forKey: viewId)

    let key = currentKey
    var bucket = live[key] ?? []
    bucket.removeAll { $0.value == nil || $0.value === view }

    // Prefer the most recently-registered twin that's still ATTACHED to a
    // window. Without this filter, rapid push/pop cycles can leave a stale
    // outgoing view in the bucket — `captureSnapshot()` would then return
    // nil for that stale source and the flight would silently abort.
    let twin = bucket.reversed().first(where: {
      guard let v = $0.value else { return false }
      return v.contentView.window != nil
    })?.value
    bucket.append(WeakBox(view))
    live[key] = bucket

    NSLog("[SharedHeroRegistry] register view=\(Self.id(view)) key=\(key) bucketSize=\(bucket.count) twin=\(twin.map { Self.id($0) } ?? "nil") sameWindow=\(twin.map { $0.contentView.window === view.contentView.window } ?? false)")

    if let twin = twin, twin !== view {
      runTwinFlight(source: twin, dest: view)
      return
    }

    // SEPARATE-WINDOW REAPPEARANCE (e.g. core `<Modal>` dismiss): a source
    // hero for this key already unregistered during this matching window and
    // is parked in `recentlyUnregistered` waiting for the match-pass to fire
    // its back-flight. The view registering now is that flight's DESTINATION —
    // the underlying list cell re-attaching after the modal's own UIWindow was
    // torn down. Hide it the instant it attaches, in THIS synchronous register
    // turn, so it never paints at its resting position for the frame or two
    // before `runMatchPass` adds the overlay. Without this the just-revealed
    // list cell flashes at the bottom and the snapshot then appears at the
    // (top-of-screen) modal source position — which reads as the hero
    // "teleporting" to the top. The imminent match-pass keeps it hidden and
    // reveals it under the landing overlay (and `pollOnce`'s timeout un-hides
    // it if no flight ever lands, so we can never strand it hidden).
    //
    // Skip when the parked source is this SAME view instance: that's a
    // host-navigator reparent churn the match-pass deliberately ignores
    // (`matchPass skip same-id churn`), so hiding here would leave the view
    // hidden with no flight to reveal it.
    if let pendingSource = recentlyUnregistered[key],
       pendingSource.sourceViewId != ObjectIdentifier(view) {
      view.setHiddenForFlight(true)
    }

    pendingKeys.insert(key)
    scheduleMatchPass()
  }

  /// Marks `view` as having its back-transition owned by
  /// `InteractiveModalReturn` (the swipe-to-dismiss overlay). Reuses the
  /// `alreadyFlighted` set so the deferred `commitUnregister` takes its
  /// source-already-flighted early-return branch instead of starting a
  /// duplicate back-flight.
  func markInteractivelyHandled(_ view: SharedHeroViewImpl) {
    alreadyFlighted.insert(ObjectIdentifier(view))
  }

  /// Reverses `markInteractivelyHandled` when an interactive return is
  /// cancelled (the sheet snapped back) so a future genuine dismiss isn't
  /// suppressed.
  func unmarkInteractivelyHandled(_ view: SharedHeroViewImpl) {
    alreadyFlighted.remove(ObjectIdentifier(view))
  }

  func unregister(_ view: SharedHeroViewImpl) {
    // CHURN-DEFER: defer the actual unregister work to the next runloop
    // tick. If the SAME view re-registers within the tick (host navigator
    // reparenting — see the `pendingUnregisters` doc), `register` will
    // pull this entry out of `pendingUnregisters` and the commit becomes
    // a no-op. Otherwise the async block fires and we run the real
    // unregister.
    //
    // The one-tick delay is well-tolerated by every legitimate consumer:
    //  - Forward-push end-of-push unmount: the LIST screen is already
    //    off-window by the time RNS tears it down; an extra runloop
    //    tick of "still registered" makes no visible difference because
    //    `alreadyFlighted` still short-circuits the unregister-twin
    //    fast path.
    //  - Pop start of pop: the back-flight gets queued one tick later
    //    than before; the pop animation runs over many ticks, so
    //    there's no user-visible difference.
    //  - In-place match: same as pop.
    let viewId = ObjectIdentifier(view)
    let key = Self.key(for: view)
    // If we're already pending an unregister for this view, leave the
    // existing entry alone (it's the same key/view, idempotent).
    if pendingUnregisters[viewId] == nil {
      // Capture the in-place baseline NOW, while the view's stash + last
      // stable frame are still valid. `prepareToLeaveWindow`
      // (willMoveToWindow:) has just refreshed the bitmap; a later capture
      // in the churn-cancel branch would miss it if Fabric recycles the
      // component (InPlaceToggle). We use `inPlaceBaselineSnapshot()` (not
      // `captureOrCachedSnapshot()`) so the SOURCE rect comes from the
      // layout-metrics-derived stable frame rather than a torn mid-toggle
      // capture — otherwise the in-place flight starts 100pt off (the
      // small-size box at the large-size origin).
      let baseline = view.inPlaceBaselineSnapshot()
      pendingUnregisters[viewId] = PendingUnregister(view: view, key: key, baseline: baseline, returnFlightEnabled: view.config.returnFlightEnabled)
    }
    NSLog("[SharedHeroRegistry] unregister DEFER view=\(Self.id(view)) key=\(key) baseline=\(pendingUnregisters[viewId]?.baseline?.settledFrame.debugDescription ?? "nil") pendingCount=\(pendingUnregisters.count)")
    DispatchQueue.main.async { [weak self, weak view] in
      guard let self = self else { return }
      let pending = self.pendingUnregisters.removeValue(forKey: viewId)
      // pending is nil → register() cancelled the churn. No-op.
      guard let pending = pending else { return }
      // Pass the ORIGINAL key (captured at unregister time) explicitly
      // instead of recomputing via `Self.key(for: view)` — the view's
      // config may have been mutated between unregister and commit
      // (e.g. `prepareForRecycle` resets `config = SharedHeroConfig()`
      // immediately after calling `unregister(self)`), in which case
      // `Self.key(for: view)` would return a fresh "default::" and miss
      // the live bucket entry.
      if let view = view {
        self.commitUnregister(view: view, key: pending.key, baseline: pending.baseline, returnFlightEnabled: pending.returnFlightEnabled)
      } else {
        // View is dead. Just clean the bucket entry under the original key.
        var bucket = self.live[pending.key] ?? []
        bucket.removeAll { $0.value == nil }
        if bucket.isEmpty {
          self.live.removeValue(forKey: pending.key)
        } else {
          self.live[pending.key] = bucket
        }
      }
    }
  }

  /// Real unregister logic, run from the next runloop tick after the
  /// initial unregister call — see `unregister(_:)` for the churn
  /// rationale. `key` is the namespace::id key captured at the original
  /// `unregister` call; we deliberately do NOT recompute via
  /// `Self.key(for: view)` since the view's config may have been mutated
  /// in the interim (e.g. by `prepareForRecycle`).
  private func commitUnregister(view: SharedHeroViewImpl, key: String, baseline: HeroSnapshot? = nil, returnFlightEnabled: Bool = true) {
    NSLog("[SharedHeroRegistry] unregister COMMIT view=\(Self.id(view)) key=\(key)")
    // A genuine unregister supersedes any in-place watch we had queued for
    // this instance (e.g. the view was torn down before it ever resized).
    pendingInPlace.removeValue(forKey: ObjectIdentifier(view))
    if var bucket = live[key] {
      bucket.removeAll { $0.value === view || $0.value == nil }
      if bucket.isEmpty {
        live.removeValue(forKey: key)
      } else {
        live[key] = bucket
      }
    }

    if alreadyFlighted.remove(ObjectIdentifier(view)) != nil {
      // The unregistering view was the SOURCE of a recent twin-flight
      // (typically the list-side hero whose host screen was just torn down
      // by react-native-screens after a forward push). Refresh the
      // registry cache before returning so a *future* forward flight
      // (tap-A → back → tap-A → back → tap-A) has a snap to fall back to
      // if the re-registered source view's live capture momentarily
      // returns nil. We intentionally restrict cache writes from unregister
      // to this branch — the OTHER branch handles detail-side views being
      // torn down, whose snaps would CORRUPT the cache for the same key
      // (a future forward flight would fly the destination's bitmap from
      // its destination position, producing a "no flight" appearance).
      if let snap = view.captureOrCachedSnapshot() {
        lastKnownSnapshots[key] = snap
      }
      return
    }

    // Opt-out: a hero declared `returnFlightEnabled = false` performs a quiet
    // teardown — it never initiates a return/back-flight on unmount. Used by
    // the core `<Modal>` example whose dismiss is a plain slide-DOWN that
    // carries the hero off-screen with it; firing a back-flight here would
    // redundantly fly the (now off-screen, bottom) snapshot back up to the
    // list cell after the slide finishes. We've already cleared this view's
    // bucket entry and any in-place watch above, so there's nothing else to
    // do. (`returnFlightEnabled` is captured at the original `unregister`
    // call — the view's config may have been reset by the time this deferred
    // commit runs.)
    if !returnFlightEnabled {
      NSLog("[SharedHeroRegistry] unregister quiet teardown (returnFlightEnabled=false) view=\(Self.id(view)) key=\(key)")
      return
    }

    // `captureOrCachedSnapshot` falls back to the snapshot stashed in
    // `prepareToLeaveWindow()` if the view is already out of the window. The
    // `?? baseline` is the last-resort source: on a UIKit-modal DISMISS the
    // detail (source) hero is torn down off-window and — depending on the
    // recycle/teardown ordering — both its live render AND its view-level
    // stash can already be gone by the time this deferred commit runs (the
    // logged "captureSnapshot returned nil (no live & no stash)"). The
    // `baseline` was captured at the original `unregister` call, while the
    // stash was still valid, and carries the modal-position frame + bitmap we
    // need as the back-flight's SOURCE.
    let snap = view.captureOrCachedSnapshot() ?? baseline

    // Twin back-flight path. Prefer a sibling twin that is still ATTACHED to
    // the window (the destination was never detached — e.g. a native-stack
    // pop where both screens are on-window during the transition, or a parent
    // navigator that keeps both attached). If none is attached, fall back to
    // an OFF-WINDOW twin: this is the UIKit-modal DISMISS case. The underlying
    // LIST screen that owns the back-flight's true destination twin is kept
    // OFF-window by react-native-screens for the duration of the modal present
    // (and re-attaches only as the dismiss animation reveals it). The twin is
    // the SAME instance that simply re-attaches — it never re-registers — so
    // neither the twin-on-register path nor the match-pass (which only fires
    // for keys that newly registered this tick) ever triggers, and the
    // back-flight was being silently dropped.
    //
    // We queue the flight against that off-window twin and lean on
    // `pollOnce`'s wall-clock-bounded pre-attach wait (`everAttached` /
    // `attachDeadline`, the mirror of the forward modal fix): the poll holds
    // the flight WITHOUT consuming the layout-settle budget until the twin
    // re-attaches, then fires once it settles. If the twin is torn down before
    // it ever re-attaches, the deadline elapses and `pollOnce` un-hides it, so
    // we never leave the list thumbnail invisible.
    if let snap = snap,
       let liveTwin = (live[key]?.reversed().first(where: { box in
         guard let v = box.value else { return false }
         return v !== view && v.contentView.window != nil
       }) ?? live[key]?.reversed().first(where: { box in
         guard let v = box.value else { return false }
         return v !== view
       }))?.value {
      // Interactive UIKit-modal (pageSheet) SWIPE-to-dismiss: the system
      // gesture slides the WHOLE sheet (and the detail hero with it) off the
      // bottom of the screen under the user's finger, and React-Navigation
      // unmounts the modal screen — which triggers THIS unregister and the
      // back-flight — only AFTER the dismiss animation has fully completed.
      // By then the underlying LIST is already revealed with its thumbnail
      // settled in place (the native sheet dismissal produced a clean
      // reveal on its own). Firing a back-flight at this point hides that
      // settled thumbnail and flies a late, redundant overlay in from the
      // (off-screen) source position — the reported glitch.
      //
      // Detect this via the captured source sitting (mostly) below the
      // bottom of the screen and SUPPRESS the flight, leaving the
      // destination visible exactly where the sheet already revealed it.
      //
      // The button-dismiss path is unaffected: React-Navigation's
      // `goBack()` unmounts the screen at the START of the dismiss, so the
      // source is captured on-screen (or falls back to the on-screen
      // `baseline`) and the overlapping flight looks correct. The
      // GestureReturn drag-to-dismiss is likewise unaffected: it pops at a
      // moderate drag offset, so the source's center is still on-screen and
      // the slingshot fires as before.
      let screenHeight = view.contentView.window?.bounds.height
        ?? liveTwin.contentView.window?.bounds.height
        ?? UIScreen.main.bounds.height
      if snap.frame.midY >= screenHeight {
        NSLog("[SharedHeroRegistry] back-flight SUPPRESSED (interactive swipe dismiss — source offscreen snapMidY=\(snap.frame.midY) screenH=\(screenHeight)) dest=\(Self.id(liveTwin))")
        // Defensive: make sure the revealed thumbnail isn't left hidden by
        // any stale flight state.
        liveTwin.setHiddenForFlight(false)
        return
      }

      // Record this back-flight's source frame for the NEXT forward push's
      // `destFrameHint` (by push/pop symmetry — see `lastFlightSourceFrame`).
      // Cache the SETTLED frame, not the (possibly transformed) `snap.frame`:
      // after a drag-to-dismiss the snap's window frame reflects the user's
      // drag offset, whereas the next forward push's dest lays out at the
      // natural (untransformed) position, which is what the hint must match.
      lastFlightSourceFrame[key] = snap.settledFrame != .zero ? snap.settledFrame : snap.frame
      let twinAttached = liveTwin.contentView.window != nil
      NSLog("[SharedHeroRegistry] unregister-twin fire source=\(Self.id(view)) dest=\(Self.id(liveTwin)) twinAttached=\(twinAttached) cached=\(lastFlightSourceFrame[key]?.debugDescription ?? "nil")")
      alreadyFlighted.insert(ObjectIdentifier(view))
      liveTwin.setHiddenForFlight(true)
      // No `destFrameHint` for the back-flight: the only returns that still
      // reach this path are NON-interactive, TRANSFORM-driven (a button pop or
      // a modal button-dismiss), for which `settledWindowFrame()` already
      // neutralises the in-progress parallax and reports the correct resting
      // rect. So we let `pollOnce` fire on the freshly-sampled settled frame
      // and land there. (Interactive left-edge swipe-backs — fast OR slow — are
      // now fully owned by `InteractiveStackPop`, which marks the detail
      // `interactivelyHandled` so this branch never runs for them; the stale
      // `destFrameHint` it used to pin to was the source of the fast-swipe
      // jump-to-top.)
      queuePendingFlight(snap: snap, source: view, dest: liveTwin)
      return
    }

    if let snap = snap {
      recentlyUnregistered[key] = RecentlyUnregisteredEntry(snap: snap, sourceViewId: ObjectIdentifier(view))
    }
    pendingKeys.insert(key)
    scheduleMatchPass()
  }

  // MARK: - Twin-register path (covers native-stack push & pop).

  private func runTwinFlight(source: SharedHeroViewImpl, dest: SharedHeroViewImpl) {
    let key = Self.key(for: source)
    // Grab the previous flight's source frame BEFORE we overwrite it below.
    // By push/pop symmetry, that's the EXPECTED LANDING RECT of the current
    // dest. Two consecutive flights for the same key swap roles (push:
    // source=list, dest=detail → pop: source=detail, dest=list), so the
    // previous source's window frame is exactly where the current dest
    // should end up. We pass it to `pollOnce` as `destFrameHint` so the
    // poll loop can ignore transient mid-relayout `settled` reads and wait
    // for the real one.
    let destFrameHint = lastFlightSourceFrame[key]

    // Resolution order for the source snapshot:
    //  1. Live render via `captureSnapshot()` (which itself falls back to
    //     the view-level stash on failure).
    //  2. Registry-level `lastKnownSnapshots[key]` — covers the case where
    //     the source view's stash was also lost (view recycled, briefly
    //     dealloc'd by Fabric, etc.).
    //
    // Without the registry-level fallback the twin-flight path silently
    // aborts and the user just sees a screen fade with no hero animation,
    // which is exactly the regression reported for "tap A → back → tap A
    // → ... fades after a few cycles".
    let liveSnap: HeroSnapshot
    if let live = source.captureSnapshot() {
      liveSnap = live
      lastKnownSnapshots[key] = live
    } else if let cached = lastKnownSnapshots[key] {
      NSLog("[SharedHeroRegistry] runTwinFlight using registry-cached snap source=\(Self.id(source)) key=\(key)")
      liveSnap = cached
    } else {
      NSLog("[SharedHeroRegistry] runTwinFlight abort: source snapshot is nil and no cache source=\(Self.id(source)) key=\(key) inWindow=\(source.contentView.window != nil) bounds=\(source.contentView.bounds)")
      return
    }

    // `runTwinFlight` only fires on the FORWARD push (a new dest registered
    // while the existing source twin is still attached). By the time this
    // runs the host navigator's push animation has already STARTED —
    // `react-native-screens` uses a `UIViewPropertyAnimator` driving
    // `view.transform = CGAffineTransformMakeTranslation(-0.3 * W, 0)` on
    // the previous screen (parallax) — so `source.windowFrame()` (which
    // uses `convert(_:to:window)` and therefore respects ancestor
    // transforms) reports a position SHIFTED LEFT by however far the
    // parallax has progressed.
    //
    // If we used `liveSnap.frame` directly as the flight's start rect, the
    // overlay would appear at the parallax-shifted position instead of the
    // natural source position the user actually tapped. On `ArcPath` (which
    // uses the default slide-from-right animation, NOT `fade`) this is
    // visible as "the hero slides from the LEFT into the destination" —
    // because the start rect is at the parallax x ≈ source.naturalX - 0.3 * W,
    // and the arc curve carries that left-shifted start over to the
    // destination center.
    //
    // The settled frame is computed from the layer chain's `position`
    // (NOT `transform`), so it always reflects the NATURAL window-space
    // rect regardless of any in-progress host parallax/slide. We rebuild
    // `snap` here so FlightEngine starts the overlay at the natural
    // source position.
    //
    // (back-pop uses the `unregister`-twin path below, which intentionally
    // keeps `snap.frame` — its frame reflects user-applied transforms like
    // `<Animated.View translateY={dragOffset}>` so the back-flight starts
    // from the dragged position. By the time `prepareToLeaveWindow` fires
    // the host pop animation has finished and react-native-screens has
    // already reset the screen's transform to identity, so user-applied
    // transforms are the only delta between `frame` and `settledFrame`.)
    let snap = HeroSnapshot(
      image: liveSnap.image,
      frame: liveSnap.settledFrame != .zero ? liveSnap.settledFrame : liveSnap.frame,
      settledFrame: liveSnap.settledFrame,
      cornerRadius: liveSnap.cornerRadius,
      backgroundColor: liveSnap.backgroundColor
    )

    // Record this flight's source frame for the NEXT flight's hint. Use
    // the SETTLED (untransformed) frame so a future flight whose dest
    // lays out at the natural position can match the hint — see comment
    // in the unregister-twin path for the drag-dismiss failure mode.
    lastFlightSourceFrame[key] = snap.settledFrame != .zero ? snap.settledFrame : snap.frame
    NSLog("[SharedHeroRegistry] runTwinFlight source=\(Self.id(source)) dest=\(Self.id(dest)) sourceFrame=\(source.windowFrame()) liveFrame=\(liveSnap.frame) settledFrame=\(liveSnap.settledFrame) destFrameHint=\(destFrameHint?.debugDescription ?? "nil")")

    // INTERACTIVE EDGE-SWIPE POP.
    //
    // This same `runTwinFlight` path fires for BOTH directions: a forward push
    // (a new dest registers while its twin is attached) AND a native-stack pop
    // (the screen below re-attaches + re-registers, finding the leaving detail
    // as its twin). For an interactive left-edge swipe-back the time-driven
    // flight below is exactly wrong: it fires at swipe-START, ignores the
    // finger, and — on a slow swipe — its 2 s poll times out mid-gesture and
    // lands on the still-sliding parallax position (the reported "flies to the
    // wrong position"). See the log analysis.
    //
    // If `source` is the detail hero an interactive pop controller is armed on
    // (from its forward push) AND the host nav controller reports an
    // INTERACTIVE transition in progress (the swipe gesture — NOT a programmatic
    // push or a button pop), hand the whole back-transition to
    // `InteractiveStackPop` and SKIP the time-driven flight + the unconditional
    // re-arm below. The controller refreshes its destination to the fresh
    // re-entering `dest` twin and drives the overlay from the finger into the
    // list thumbnail. Forward pushes and button pops return false here and keep
    // their normal morph flight untouched.
    //
    // NOTE: `lastFlightSourceFrame[key]` is recorded ABOVE this point so the
    // NEXT forward push still gets the correct symmetric landing hint even when
    // we defer this flight.
    if InteractiveStackPop.shared.tryAdoptInteractivePop(detail: source, dest: dest, sourceSnap: snap) {
      NSLog("[SharedHeroRegistry] runTwinFlight DEFERRED to InteractiveStackPop (interactive pop) source=\(Self.id(source)) dest=\(Self.id(dest))")
      return
    }

    alreadyFlighted.insert(ObjectIdentifier(source))
    // Hide the DESTINATION now — it's about to be mounted/laid out by Fabric
    // and we don't want it to flash visible before the flight overlay lands.
    //
    // Intentionally DO NOT hide the source yet. Hiding it here would commit a
    // "source disappears" frame to the screen before the overlay snapshot is
    // ready (we still need to wait for the dest to be laid out). The source
    // is hidden in `tryFire(...)` in the same runloop tick as the flight
    // overlay is added, so CATransaction batches both changes and the user
    // sees a seamless source→snapshot swap with no blank gap.
    dest.setHiddenForFlight(true)
    queuePendingFlight(snap: snap, source: source, dest: dest, destFrameHint: destFrameHint)

    // Arm interactive return tracking. Both controllers are cheap to arm for
    // every twin flight and are mutually exclusive by context — each stands
    // down once `dest` settles on-window if the context isn't theirs:
    //   * `InteractiveModalReturn` owns swipe-DOWN dismiss of sheet modals
    //     (`presentation: 'modal'`/`'formSheet'`).
    //   * `InteractiveStackPop` owns the left-edge swipe-BACK pop of a
    //     native-stack push (the parallax-slide case the time-driven
    //     back-flight could never track). On activation it marks the detail
    //     `interactivelyHandled`, so the end-of-pop `commitUnregister`
    //     back-flight stands down and we own the return.
    InteractiveModalReturn.shared.arm(detail: dest, twin: source)
    InteractiveStackPop.shared.arm(detail: dest, twin: source)
  }

  /// Queue a flight for `dest` once its layout is stable. The polling chain
  /// in `pollOnce(_:)` runs once per runloop tick (via chained
  /// `DispatchQueue.main.async`) and only fires when two consecutive samples
  /// agree.
  ///
  /// Two consecutive samples from DIFFERENT runloop ticks is required because:
  /// 1. On native-stack pop, the re-attached dest's `bounds` are preserved
  ///    from the previous mount (so settled reads non-zero immediately), but
  ///    Fabric may still be committing the ancestor chain's layer positions
  ///    — firing on the first sample lands at the wrong cell.
  /// 2. On forward push, the fresh dest's `bounds` start at zero, so the
  ///    first sample fails the `!= .zero` guard; we record the first valid
  ///    sample once layout reports it and fire on the next matching one.
  private func queuePendingFlight(
    snap: HeroSnapshot,
    source: SharedHeroViewImpl?,
    dest: SharedHeroViewImpl,
    destFrameHint: CGRect? = nil
  ) {
    let key = ObjectIdentifier(dest)
    pendingFlights[key] = PendingFlight(
      snap: snap,
      source: source,
      lastSampledFrame: nil,
      destFrameHint: destFrameHint,
      attemptsLeft: maxLayoutAttempts,
      everAttached: dest.contentView.window != nil,
      attachDeadline: CACurrentMediaTime() + maxAttachWaitSeconds
    )
    NSLog("[SharedHeroRegistry] queuePendingFlight dest=\(Self.id(dest)) source=\(source.map { Self.id($0) } ?? "nil") destFrameHint=\(destFrameHint?.debugDescription ?? "nil")")
    schedulePoll(dest: dest)
  }

  /// Called synchronously from `SharedHeroViewImpl.didUpdateLayoutMetrics()`
  /// (Fabric's `updateLayoutMetrics:`) and from `didMoveToWindow(_:)` on
  /// attach. Drives the in-place fast path: if the view is being watched
  /// for an in-place resize (`pendingInPlace`) and its NEW frame differs
  /// in SIZE from the captured baseline, fire the flight RIGHT NOW — in
  /// the same runloop turn the new layout is applied — so the new state is
  /// committed already hidden and never renders uncovered.
  ///
  /// This fixes the "tap → flash destination state → rewind to source →
  /// animate" glitch: the async `pollInPlace` fallback only hides the view
  /// a tick AFTER the new layout has already committed and rendered.
  /// Reacting on the layout/attach event itself closes that window.
  ///
  /// Safety:
  ///   * We read `settledWindowFrame()` (NOT a shim frame). It returns
  ///     `.zero` for zero/degenerate bounds, so a not-yet-laid-out attach
  ///     simply bails here and is picked up later by `pollInPlace`; we
  ///     never fire on a transient frame.
  ///   * It is transform-aware, so an in-progress host-navigator parallax
  ///     can't inflate/shift the rect — and we key off SIZE only, which a
  ///     reparent never changes. Navigation flights have no
  ///     `pendingInPlace` entry, so they're untouched.
  func notifyLayoutReady(_ view: SharedHeroViewImpl) {
    let viewId = ObjectIdentifier(view)
    guard let p = pendingInPlace[viewId] else { return }

    // A flight is already running on this instance (rapid toggling) — drop
    // the watch; the running flight lands at the real layout.
    if currentlyFlying.contains(viewId) {
      pendingInPlace.removeValue(forKey: viewId)
      return
    }

    let dest = view.settledWindowFrame()
    guard dest != .zero else { return }

    let b = p.baseline.settledFrame
    let tol = inPlaceChangeThreshold
    let changed =
      abs(dest.width - b.width) > tol ||
      abs(dest.height - b.height) > tol
    // No SIZE change (reparent, or layout not applied yet) — leave the
    // entry for `pollInPlace` to re-check / discard.
    guard changed else { return }

    pendingInPlace.removeValue(forKey: viewId)
    currentlyFlying.insert(viewId)
    NSLog("[SharedHeroRegistry] in-place fire (sync layout) view=\(Self.id(view)) baseline=\(b) dest=\(dest)")
    // Hide + add the overlay synchronously in THIS layout transaction so
    // CoreAnimation batches the hide with the new-layout commit — the
    // destination state never appears uncovered. We pass `dest` as the
    // override since we just resolved it.
    view.setHiddenForFlight(true)
    FlightEngine.shared.run(
      from: p.baseline,
      sourceView: nil,
      to: view,
      destFrameOverride: dest
    ) { [weak self] in
      self?.currentlyFlying.remove(viewId)
    }
  }

  private func schedulePoll(dest: SharedHeroViewImpl) {
    DispatchQueue.main.async { [weak self, weak dest] in
      guard let self = self, let dest = dest else { return }
      self.pollOnce(dest: dest)
    }
  }

  private func scheduleInPlaceCheck(view: SharedHeroViewImpl) {
    DispatchQueue.main.async { [weak self, weak view] in
      guard let self = self, let view = view else { return }
      self.pollInPlace(view: view)
    }
  }

  /// ASYNC FALLBACK to the synchronous `notifyLayoutReady(_:)` path.
  ///
  /// Watches a churn-cancelled view (see `pendingInPlace`) for a genuine
  /// layout change. Fires a self-flight the moment the view settles at a
  /// frame that differs from the captured baseline; gives up (treats it as
  /// a reparent) if the frame stays put for `inPlaceMaxAttempts` ticks.
  ///
  /// In the common case `notifyLayoutReady` fires first (on the layout /
  /// attach event) and removes the `pendingInPlace` entry, so this poll
  /// no-ops. It remains as a safety net for any path where neither event
  /// delivers a usable on-window frame in time — but note it hides the
  /// view a tick LATE, so a flight that goes through here can show the
  /// one-frame destination-state flash the sync path avoids.
  private func pollInPlace(view: SharedHeroViewImpl) {
    let viewId = ObjectIdentifier(view)
    guard var p = pendingInPlace[viewId] else { return }

    let settled = view.settledWindowFrame()
    let attached = view.contentView.window != nil

    if attached, settled != .zero {
      let b = p.baseline.settledFrame
      let tol = inPlaceChangeThreshold
      // SIZE change only — deliberately NOT origin. A host-navigator push
      // parallax-shifts a sibling hero's origin by up to ~30% of the
      // screen width while the transition runs, and `settledWindowFrame`
      // can transiently report that shifted origin; keying off position
      // would mistake that for an in-place move and fly a ghost snapshot
      // (the exact ArcPath regression). A genuine in-place transition
      // (e.g. InPlaceToggle 120pt→320pt) always changes the view's
      // intrinsic SIZE, which no navigator parallax ever does.
      let changed =
        abs(settled.width - b.width) > tol ||
        abs(settled.height - b.height) > tol
      if changed {
        pendingInPlace.removeValue(forKey: viewId)
        // A flight may have started on this view in the meantime (rapid
        // toggling). Bail rather than stacking overlays — the view is
        // already at its real layout, so the worst case is the latest
        // toggle lands without animation.
        if currentlyFlying.contains(viewId) {
          NSLog("[SharedHeroRegistry] in-place skip (already flying) view=\(Self.id(view))")
          return
        }
        NSLog("[SharedHeroRegistry] in-place fire view=\(Self.id(view)) baseline=\(b) settled=\(settled)")
        // Fire the flight DIRECTLY (not via `queuePendingFlight`): we've
        // already verified the destination's settled frame here, so the
        // poll loop would only add a one-runloop-tick delay between hiding
        // the real view and adding the overlay. For a navigation flight
        // that gap is masked by the screen transition, but an in-place
        // morph has no transition, so the gap shows as a one-frame blank
        // (the "image blinks" report). Hiding the view and adding the
        // overlay in the SAME tick removes the blink.
        currentlyFlying.insert(viewId)
        view.setHiddenForFlight(true)
        FlightEngine.shared.run(
          from: p.baseline,
          sourceView: nil,
          to: view,
          destFrameOverride: settled
        ) { [weak self] in
          self?.currentlyFlying.remove(viewId)
        }
        return
      }
    }

    p.attemptsLeft -= 1
    if p.attemptsLeft <= 0 {
      pendingInPlace.removeValue(forKey: viewId)
      NSLog("[SharedHeroRegistry] in-place discard (no resize → treated as reparent) view=\(Self.id(view)) settled=\(settled)")
      return
    }
    pendingInPlace[viewId] = p
    scheduleInPlaceCheck(view: view)
  }

  /// Tolerance (in points) for matching a freshly-sampled `settled` frame
  /// against the cached `destFrameHint`. Sub-pixel jitter from Fabric's
  /// layout rounding is fine — only off-by-padding (≥ a few points) means
  /// the layout is genuinely still in flux.
  private let hintMatchTolerance: CGFloat = 4

  /// Single polling tick. Fires the flight when:
  ///   • A `destFrameHint` is present and the current `settled` matches it
  ///     within `hintMatchTolerance` — this is the strong path used for
  ///     every back-flight (and every forward push after the first cycle),
  ///     and it deliberately discards a "stable but wrong" pair of samples.
  ///   • No hint exists (very first flight for this key) and two
  ///     consecutive ticks read the same non-zero `settled` — the legacy
  ///     stability check, which still covers the bootstrap case.
  /// Otherwise the current sample is recorded and another poll is scheduled.
  private func pollOnce(dest: SharedHeroViewImpl) {
    let key = ObjectIdentifier(dest)
    guard var pending = pendingFlights[key] else { return }

    let settled = dest.settledWindowFrame()
    let attached = dest.contentView.window != nil
    let isReady = attached && settled != .zero

    if attached {
      pending.everAttached = true
    } else if !pending.everAttached {
      // The destination registered and queued this flight before it was
      // attached to a window — and it still hasn't attached. A UIKit modal
      // (react-native-screens `presentation: 'modal'`/`'transparentModal'`)
      // keeps its presented content off-window until the present animation
      // completes, which is past the normal layout-settle budget. Keep the
      // flight queued and keep polling WITHOUT consuming `attemptsLeft`, so
      // we're still here to fire the instant the modal attaches the hero.
      // Bounded by a wall-clock deadline so a destination that is torn down
      // before it ever attaches unhides instead of staying hidden.
      if let deadline = pending.attachDeadline, CACurrentMediaTime() > deadline {
        pendingFlights.removeValue(forKey: key)
        NSLog("[SharedHeroRegistry] gave up waiting for dest to ATTACH dest=\(Self.id(dest))")
        pending.source?.setHiddenForFlight(false)
        dest.setHiddenForFlight(false)
        return
      }
      pendingFlights[key] = pending
      schedulePoll(dest: dest)
      return
    }

    let matchesHint: Bool
    if let hint = pending.destFrameHint {
      let tol = hintMatchTolerance
      matchesHint = abs(settled.origin.x - hint.origin.x) < tol &&
                    abs(settled.origin.y - hint.origin.y) < tol &&
                    abs(settled.width - hint.width) < tol &&
                    abs(settled.height - hint.height) < tol
    } else {
      matchesHint = false
    }

    let canFire: Bool
    if pending.destFrameHint != nil {
      // Strong path (forward push & match-pass): trust the cached symmetric
      // rect over a transient `settled` — keep waiting for `settled` to agree
      // with the hint so an early/mislaid sample can't fire.
      canFire = isReady && matchesHint
    } else {
      // No hint: the first-ever flight on this key OR a back-flight (button
      // pop / modal button-dismiss). Both fire on the legacy
      // two-consecutive-settled-samples check and land at the freshly-sampled
      // `settled` — which is correct for these transform-driven returns.
      canFire = isReady && pending.lastSampledFrame == settled
    }

    if canFire {
      // Suppress duplicate firing for the same destination — if a previous
      // flight is still animating, drop this one so we don't stack overlays
      // / re-hide the source mid-flight.
      if currentlyFlying.contains(key) {
        NSLog("[SharedHeroRegistry] DUPLICATE FLIGHT SUPPRESSED dest=\(Self.id(dest))")
        pendingFlights.removeValue(forKey: key)
        pending.source?.setHiddenForFlight(false)
        dest.setHiddenForFlight(false)
        return
      }
      pendingFlights.removeValue(forKey: key)
      currentlyFlying.insert(key)
      NSLog("[SharedHeroRegistry] flight fire dest=\(Self.id(dest)) sampledSettled=\(settled) destVisible=\(dest.windowFrame()) hint=\(pending.destFrameHint?.debugDescription ?? "nil") sourceSnap=\(pending.snap.frame) sourceSettled=\(pending.snap.settledFrame) attemptsUsed=\(maxLayoutAttempts - pending.attemptsLeft)")
      // One-shot layer-chain dump for the destination. Lets us correlate
      // a wrong `settled` rect against the actual ancestor positions and
      // transforms; if e.g. `settledWindowFrame()` is returning a
      // parallax-shifted rect, the chain dump shows exactly which
      // ancestor still has a non-identity transform that we're failing
      // to compensate for.
      dest.dumpLayerChain(prefix: "flight-fire-dest")
      if let src = pending.source {
        src.dumpLayerChain(prefix: "flight-fire-source")
      }
      // Hide source + add overlay snapshot in the SAME runloop tick so they
      // commit together — no visible blank between source disappearing and
      // the flight overlay appearing in its place.
      //
      // We intentionally do NOT hide OTHER heros in the same namespace. An
      // earlier version did ("auxiliaryHidden") so the flying snapshot
      // would visually "own" the screen during the host-navigator
      // transition, but it produced an obvious bug on screens with
      // multiple heros far from the flight path (e.g. BasicImageHero — a
      // vertical scroll list where tapping one image made every other
      // image disappear under its caption while the flight ran, and the
      // same gap re-appeared during the back-flight as the list re-
      // entered the window). The flight overlay is already on a window-
      // level layer above everything; the natural screen transition does
      // the rest, and leaving siblings visible matches Material container-
      // transform behaviour.
      pending.source?.setHiddenForFlight(true)
      // Pin the flight's landing rect to the value we just verified, so
      // FlightEngine doesn't re-read `settledWindowFrame()` and pick up a
      // different sample one tick later. Use the hint when present
      // (slightly more authoritative than the live read — it's the rect
      // that's been stable across a full push/pop cycle for this key); a
      // back-flight has no hint and lands at the freshly-sampled `settled`.
      let landingFrame: CGRect = pending.destFrameHint ?? settled
      NSLog("[SharedHeroFlight] landing rect dest=\(Self.id(dest)) usedRect=\(landingFrame) source=\(pending.destFrameHint != nil ? "settled-hint" : "live-settled") sampledSettled=\(settled) destLive=\(dest.windowFrame()) destSettled=\(dest.settledWindowFrame())")
      // Capture `key` by value (ObjectIdentifier is a value type) instead
      // of recomputing `ObjectIdentifier(dest)` inside the completion. If
      // `dest` is dealloc'd before the completion fires (e.g. user
      // navigates away mid-flight and Fabric tears the view down), a
      // `[weak dest]` closure would early-return and leak the
      // `currentlyFlying` entry — blocking every future flight whose dest
      // happens to land at the same address.
      FlightEngine.shared.run(
        from: pending.snap,
        sourceView: pending.source,
        to: dest,
        destFrameOverride: landingFrame
      ) { [weak self] in
        self?.currentlyFlying.remove(key)
      }
      return
    }

    pending.lastSampledFrame = isReady ? settled : nil
    pending.attemptsLeft -= 1
    if pending.attemptsLeft <= 0 {
      pendingFlights.removeValue(forKey: key)
      // Last-ditch fallback: pick the best rect we can land at. Prefer the
      // current `settled` (the freshest live layout) over the cached
      // `destFrameHint` — the hint is from a previous quiescent moment, so
      // if Fabric has had 2 s to converge and `settled` still doesn't
      // match, the most likely explanation is that the destination's
      // layout has genuinely changed (orientation, list reorder, scroll)
      // and the hint is now STALE. Trusting `settled` at this point lands
      // the flight at the real current position; trusting the hint would
      // land it at the OLD position and then snap to the new one once the
      // flight completes (the exact failure mode that prompted this
      // function's existence in the first place).
      //
      // Hint is still used when `settled` is unusable (e.g. dest briefly
      // out of window), as a strict improvement over giving up entirely.
      let landing: CGRect?
      if attached, settled != .zero {
        landing = settled
      } else if let hint = pending.destFrameHint, attached {
        landing = hint
      } else {
        landing = nil
      }
      if let landing = landing {
        NSLog("[SharedHeroRegistry] poll timeout: firing dest=\(Self.id(dest)) landing=\(landing) lastSettled=\(settled) destLive=\(dest.windowFrame()) hint=\(pending.destFrameHint?.debugDescription ?? "nil")")
        currentlyFlying.insert(key)
        pending.source?.setHiddenForFlight(true)
        FlightEngine.shared.run(
          from: pending.snap,
          sourceView: pending.source,
          to: dest,
          destFrameOverride: landing
        ) { [weak self] in
          self?.currentlyFlying.remove(key)
        }
        return
      }
      NSLog("[SharedHeroRegistry] gave up waiting for dest layout dest=\(Self.id(dest))")
      pending.source?.setHiddenForFlight(false)
      dest.setHiddenForFlight(false)
      return
    }
    pendingFlights[key] = pending
    schedulePoll(dest: dest)
  }

  private let maxLayoutAttempts: Int = 120

  /// Wall-clock seconds to wait for a queued flight's destination to attach
  /// to a window for the FIRST time (see `PendingFlight.attachDeadline`).
  /// Generous enough to cover a UIKit modal present (which holds the
  /// presented hero off-window for the duration of the present animation)
  /// while still bounding a flight whose destination is never attached.
  private let maxAttachWaitSeconds: CFTimeInterval = 6

  // MARK: - In-place match-pass path (unregister → register within 1 tick).

  private func scheduleMatchPass() {
    guard !matchScheduled else { return }
    matchScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.runMatchPass()
    }
  }

  private func runMatchPass() {
    matchScheduled = false
    let keys = pendingKeys
    pendingKeys.removeAll()

    for key in keys {
      guard let dest = live[key]?.last(where: { $0.value != nil })?.value else { continue }
      guard let entry = recentlyUnregistered.removeValue(forKey: key) else { continue }

      // Churn guard (defense-in-depth — see `pendingUnregisters` doc):
      // if the dest view is the SAME instance that just unregistered
      // (host navigator reparenting the same subtree), the snap and the
      // dest both came from the SAME view, so firing a flight here would
      // animate a snapshot of the list image back onto itself — exactly
      // the "ghost image floating over the detail screen" symptom from
      // the ArcPath bug report. Skip silently.
      if entry.sourceViewId == ObjectIdentifier(dest) {
        NSLog("[SharedHeroRegistry] matchPass skip same-id churn key=\(key) dest=\(Self.id(dest))")
        continue
      }

      let snap = entry.snap
      let destFrameHint = lastFlightSourceFrame[key]
      // See `unregister(_:)` for why we cache `settledFrame`, not `frame`.
      lastFlightSourceFrame[key] = snap.settledFrame != .zero ? snap.settledFrame : snap.frame
      NSLog("[SharedHeroRegistry] matchPass fire key=\(key) dest=\(Self.id(dest)) destFrameHint=\(destFrameHint?.debugDescription ?? "nil")")
      dest.setHiddenForFlight(true)

      // FAST PATH for the separate-window reappearance (core `<Modal>`
      // dismiss): the destination (list) hero is already attached and laid
      // out at its resting position by the time the match-pass runs — the
      // underlying list never moved while the modal owned its own UIWindow,
      // so the freshly-sampled `settled` frame already agrees with the cached
      // symmetric `destFrameHint`. Routing through `queuePendingFlight` would
      // then insert one or two extra runloop ticks (the poll loop) between
      // hiding the dest above and the overlay's FIRST paint. On an
      // instant-dismiss modal those ticks are a visible blank gap — the modal
      // window is already gone — and they make the snapshot look like it pops
      // in at the (top) source position several frames late. Firing
      // synchronously commits the hide and the overlay's first frame in the
      // SAME runloop tick, at the earliest moment the destination exists, so
      // the hand-off reads as continuous: the snapshot is on screen at the
      // modal's old top position and immediately flies down to the cell.
      //
      // Strictly gated so every OTHER match-pass keeps its existing poll
      // behaviour: we only short-circuit when a hint exists AND the live
      // `settled` already matches it within tolerance. A first-ever match for
      // a key (no hint) or an in-place state-swap that resizes (settled won't
      // match the stale hint) both fall through to `queuePendingFlight`
      // unchanged.
      let destId = ObjectIdentifier(dest)
      if let hint = destFrameHint,
         !currentlyFlying.contains(destId),
         dest.contentView.window != nil {
        let settled = dest.settledWindowFrame()
        let tol = hintMatchTolerance
        let ready = settled != .zero &&
          abs(settled.origin.x - hint.origin.x) < tol &&
          abs(settled.origin.y - hint.origin.y) < tol &&
          abs(settled.width - hint.width) < tol &&
          abs(settled.height - hint.height) < tol
        if ready {
          currentlyFlying.insert(destId)
          NSLog("[SharedHeroRegistry] matchPass fire SYNC dest=\(Self.id(dest)) landing=\(hint) settled=\(settled)")
          FlightEngine.shared.run(
            from: snap,
            sourceView: nil,
            to: dest,
            destFrameOverride: hint
          ) { [weak self] in
            self?.currentlyFlying.remove(destId)
          }
          continue
        }
      }

      queuePendingFlight(snap: snap, source: nil, dest: dest, destFrameHint: destFrameHint)
    }

    recentlyUnregistered.removeAll()
  }

  // MARK: - Helpers

  static func key(for view: SharedHeroViewImpl) -> String {
    return "\(view.config.heroNamespace)::\(view.config.heroId)"
  }

  fileprivate static func id(_ view: SharedHeroViewImpl) -> String {
    return "@" + String(UInt(bitPattern: ObjectIdentifier(view).hashValue), radix: 16)
  }
}

/// Holds a weak ref so the registry never pins views in memory.
final class WeakBox {
  weak var value: SharedHeroViewImpl?
  init(_ value: SharedHeroViewImpl) {
    self.value = value
  }
}
