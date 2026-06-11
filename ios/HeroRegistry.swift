import Foundation
import QuartzCore
import UIKit

/// Process-wide registry of currently-mounted `SharedHeroViewImpl`s; drives the
/// router-agnostic match logic. Main-thread only.
///
/// Two trigger paths:
///   1. **Twin appears while another is still live** — native-stack push/pop,
///      where both screens' heroes are window-attached during the navigation.
///      We capture the existing twin's snapshot the moment the new twin
///      registers (source frame recorded *before* the navigator moves it) and
///      schedule the flight on the next tick, once the new twin is laid out.
///   2. **Existing twin unregisters, then a new one mounts within one tick** —
///      state-driven in-place transitions: one hero unmounts and is replaced
///      by a same-id sibling.
@objc public final class HeroRegistry: NSObject {
  @objc public static let shared = HeroRegistry()

  /// Currently-mounted views, keyed by `(namespace, id)`.
  private var live: [String: [WeakBox]] = [:]

  /// Views that unregistered during the current matching window, kept as source
  /// candidates for one runloop tick. The source view's `ObjectIdentifier` is
  /// stored alongside the snap so `runMatchPass` can detect "new dest is the
  /// SAME instance that just unregistered" — a host-navigator reparent churn
  /// that slipped past the `pendingUnregisters` defer (unregister committed tick
  /// N, register tick N+1). A view-to-itself flight produces a phantom snapshot
  /// of an unrelated list image over the destination (the ArcPath ghost bug).
  private struct RecentlyUnregisteredEntry {
    let snap: HeroSnapshot
    let sourceViewId: ObjectIdentifier
  }
  private var recentlyUnregistered: [String: RecentlyUnregisteredEntry] = [:]

  /// Keys whose state changed this tick and that should be re-evaluated.
  private var pendingKeys: Set<String> = []

  /// `ObjectIdentifier`s of views that already played source of a recent
  /// twin-flight, so we skip the in-place match path when they later unregister
  /// with a stale snapshot.
  private var alreadyFlighted: Set<ObjectIdentifier> = []

  /// Last successful SOURCE-side snapshot per `(namespace, id)` key. Populated
  /// only:
  ///   * `runTwinFlight` when the source's live capture succeeds (the canonical
  ///     list-side snap on every forward push).
  ///   * `unregister`'s `alreadyFlighted` branch — re-captures the source snap
  ///     once more before the host screen tears it down, as a fallback for the
  ///     next forward push.
  ///
  /// Deliberately NOT populated from a destination-side unregister (e.g. a
  /// detail hero being dismissed): mixing those snaps in would make a later
  /// forward flight render the destination's bitmap/frame — "no flight" again.
  ///
  /// Registry-level safety net for "tap A → back → tap A → ... fades without
  /// the flight after a few cycles". The view's own `stashedSnapshot` covers
  /// the source-still-around-but-empty-render case; this per-key cache also
  /// covers the source being recycled/torn down by Fabric / react-native-screens
  /// between pushes, when even the view-level stash is gone.
  private var lastKnownSnapshots: [String: HeroSnapshot] = [:]

  /// Window-frame of the most recent flight's *source* per key. Updated EVERY
  /// time a flight is queued — forward (runTwinFlight, source = list) and back
  /// (unregister-twin / re-register runTwinFlight, source = detail). Read by the
  /// NEXT flight as `destFrameHint`, exploiting push/pop symmetry:
  ///
  ///   push #1: src=list,   dest=detail → record list.frame
  ///   pop  #1: src=detail, dest=list   → hint = list.frame  (✓ matches dest)
  ///                                     → record detail.frame
  ///   push #2: src=list,   dest=detail → hint = detail.frame (✓ matches dest)
  ///                                     → record list.frame
  ///
  /// Kept SEPARATE from `lastKnownSnapshots` so the detail-side frame can be
  /// cached for symmetry without polluting the source-fallback bitmap cache.
  private var lastFlightSourceFrame: [String: CGRect] = [:]

  /// Flights queued waiting for the destination's first stable layout, keyed by
  /// the dest view's identity. Consumed by the `pollOnce(_:)` chain; first
  /// stable sample wins.
  private struct PendingFlight {
    let snap: HeroSnapshot
    weak var source: SharedHeroViewImpl?
    /// Previous tick's settled frame. We fire only when two consecutive polls
    /// (separate ticks) read the same value, so we don't land at a stale
    /// position while Fabric is still committing the re-attached subtree.
    var lastSampledFrame: CGRect?
    /// Last-known stable frame for this key from a previous quiescent moment
    /// (typically the prior flight's source side). When present, `pollOnce`
    /// waits for `settled` to converge to this rect (within tolerance) before
    /// firing, instead of trusting two identical `settled` samples that could
    /// agree on a transient WRONG layout.
    ///
    /// Motivating bug: on an interactive pop, `react-native-screens` re-attaches
    /// the previous screen at gesture start and Fabric re-applies layout to the
    /// subtree; for a tick or two the chain resolves off by the inner-container
    /// padding (a ~16pt left shift) before converging, and the legacy two-tick
    /// check fires on that transient pair so the back-flight lands wrong.
    var destFrameHint: CGRect?
    var attemptsLeft: Int
    /// Has the dest ever been window-attached since this flight was queued? A
    /// dest can register (fire `runTwinFlight`) from `updateProps`/
    /// `didUpdateConfig` BEFORE attach, and a UIKit modal (react-native-screens
    /// `presentation: 'modal'`/`'transparentModal'`) keeps its content
    /// OFF-WINDOW until the present finishes. Until first attach we must not burn
    /// `attemptsLeft` (the layout-settle budget), or the poll gives up before the
    /// modal attaches the hero and the flight is dropped ("modal opens, no flight").
    var everAttached: Bool = false
    /// Wall-clock deadline for the FIRST attach, bounding the pre-attach wait so
    /// a dest torn down before it ever attaches still unhides. Wall-clock (not a
    /// tick count) because idle `schedulePoll` hops via `DispatchQueue.main.async`
    /// back-to-back — 120 hops can elapse in a fraction of the modal present.
    var attachDeadline: CFTimeInterval?
  }
  private var pendingFlights: [ObjectIdentifier: PendingFlight] = [:]

  /// Destinations with an *active* flight (between fire and completion). We
  /// refuse a second flight for a dest while one runs, catching any
  /// duplicate-trigger path (e.g. host navigator re-emitting register/layout
  /// events mid-transition).
  private var currentlyFlying: Set<ObjectIdentifier> = []

  /// Unregister calls PENDING commit — the view called `didMoveToWindow(nil)`
  /// but we haven't yet run the side-effects (capture snap, fire back-flights,
  /// schedule match-pass). Deferred one tick so that if the SAME view
  /// re-registers within the tick (a host-navigator reparent, not a real
  /// unmount — `react-native-screens` moves the from-screen into its transition
  /// container on every push), we cancel the commit as a no-op.
  ///
  /// Symptom fixed: on an ArcPath forward push every LIST hero (Pine / Glacial /
  /// Summit / Visitor) goes window false → true within ~one tick. Without churn
  /// detection that reads as four genuine unmount/remount cycles and:
  ///   1) fires three bogus match-pass flights (Pine/Glacial/Summit unregister
  ///      with no live twin → match-pass → re-register picks them as both source
  ///      and dest), spraying three unrelated snapshots over the navigation;
  ///   2) clears `alreadyFlighted[LIST.visitor]` via register cleanup, so when
  ///      LIST.visitor truly unregisters at end of push the guard misses and the
  ///      unregister-twin fast path fires a bogus SECOND list→detail flight (the
  ///      hero "flies twice").
  ///
  /// Keyed by ObjectIdentifier (memory address): the SAME instance returns
  /// through register — Fabric doesn't allocate a new view for a reparent.
  private struct PendingUnregister {
    let view: SharedHeroViewImpl
    let key: String
    /// Appearance + geometry captured at unregister time, while the stash is
    /// still valid. Can't be recaptured in the churn-cancel branch: Fabric
    /// recycling the component (InPlaceToggle) nils `stashedSnapshot` between
    /// `unregister` and the recycled `register`. Right after `didMoveToWindow(nil)`,
    /// when `prepareToLeaveWindow` just refreshed the stash, is the last moment
    /// the old appearance is reliably available.
    let baseline: HeroSnapshot?
    /// Captured at unregister time because `config` may be reset (e.g.
    /// `prepareForRecycle`) before this deferred commit runs. When false,
    /// `commitUnregister` skips the back-flight entirely.
    let returnFlightEnabled: Bool
  }
  private var pendingUnregisters: [ObjectIdentifier: PendingUnregister] = [:]

  /// Views that hit the `register` churn-cancel branch (same view + same key
  /// re-registered within a tick) that might be an IN-PLACE transition rather
  /// than a host-navigator reparent. We can't tell at register time — Fabric
  /// hasn't applied new layout yet, so reparent and in-place toggle look
  /// identical (same `ObjectIdentifier`, same key, momentarily-unchanged bounds).
  ///
  /// So we stash the PRE-churn appearance as a baseline and poll settled frame:
  ///   • settles at a DIFFERENT rect (size or position) → genuine in-place
  ///     transition (e.g. InPlaceToggle, where one `SharedHero id="hero-inplace"`
  ///     swaps a 120pt style for 320pt and Fabric RECYCLES the same view) → fire
  ///     a self-flight from baseline rect to new rect.
  ///   • settles UNCHANGED within the attempt budget → host-navigator reparent
  ///     (ArcPath push reparents every LIST hero through the transition container
  ///     without changing layout) → discard baseline, no flight.
  private struct PendingInPlace {
    let baseline: HeroSnapshot
    var attemptsLeft: Int
  }
  private var pendingInPlace: [ObjectIdentifier: PendingInPlace] = [:]

  /// Ticks to wait for a churn-cancelled view to settle at a new frame before
  /// concluding it was a reparent (no resize). The in-place toggle applies its
  /// layout within ~1–2 ticks, so this is generous; a reparent just wastes this
  /// many cheap geometry reads then discards.
  private let inPlaceMaxAttempts: Int = 12

  /// Minimum delta (pt) in size or origin for a churn-cancelled view's new
  /// settled frame to count as a genuine in-place transition rather than layout
  /// jitter / a transform-free reparent.
  private let inPlaceChangeThreshold: CGFloat = 6

  private var matchScheduled = false

  private override init() {
    super.init()
  }

  // MARK: - Public API

  func register(_ view: SharedHeroViewImpl) {
    // Pre-warm the overlay UIWindow on the first registration. Creating it here
    // (not lazily in `FlightEngine.run`) lets it render its first empty,
    // transparent frame on a separate render-server flush before any flight adds
    // a subview — otherwise the first tap-to-fly flashes one white frame at the
    // source while the overlay window does its initial display pass.
    OverlayHost.shared.prepare()

    let viewId = ObjectIdentifier(view)

    // CHURN CANCEL: this view called didMoveToWindow(nil) this (or last) tick
    // and we deferred the unregister commit. If the SAME view + SAME key has
    // reattached, the host navigator just reparented us — not a real unmount.
    // Cancel the pending commit and keep ALL registry state (bucket membership,
    // `alreadyFlighted` / `currentlyFlying` / `pendingFlights`). Letting the
    // commit run and then continuing `register` would instead:
    //   - generate a bogus match-pass flight (view in both `recentlyUnregistered`
    //     and `pendingKeys` for the same key);
    //   - clear `alreadyFlighted[self]`, so the genuine end-of-push unregister
    //     fires the unregister-twin back-flight bug.
    // The view is still in `live[key]` (commit never ran), so nothing else to do.
    //
    // KEY-CHANGED branch: if pending but the current key differs, Fabric recycled
    // this instance for a different component (`prepareForRecycle` calls
    // `unregister(self)` with the OLD key, then `updateProps` mounts a new
    // component and `register(self)`s the NEW key). Commit the pending unregister
    // NOW (old key, old state), then fall through to register the new key — else
    // we'd churn-cancel across ids and leave the old key's bucket entry dangling.
    let currentKey = Self.key(for: view)
    if let pending = pendingUnregisters[viewId] {
      if pending.key == currentKey {
        pendingUnregisters.removeValue(forKey: viewId)
        // EITHER a host-navigator reparent (no SIZE change → cancel) OR a
        // Fabric-recycled in-place transition (size changes → should fly). Can't
        // decide here — new layout metrics aren't applied yet — so stash the
        // unregister-time baseline; `notifyLayoutReady(_:)` decides (and fires)
        // synchronously the instant the new layout/attach arrives, with
        // `pollInPlace` as async fallback. Both key off SIZE only: an RNS push
        // transiently parallax-shifts a sibling's origin, which must not read as
        // an in-place move. Skip if a flight is running or a baseline is queued.
        if pendingInPlace[viewId] == nil,
           !currentlyFlying.contains(viewId),
           let baseline = pending.baseline,
           baseline.settledFrame != .zero {
          pendingInPlace[viewId] = PendingInPlace(baseline: baseline, attemptsLeft: inPlaceMaxAttempts)
          heroLog(HeroLog.registry, "register CHURN-CANCEL view=\(Self.id(view)) key=\(currentKey) — watching for in-place resize baseline=\(baseline.settledFrame)")
          scheduleInPlaceCheck(view: view)
        } else {
          heroLog(HeroLog.registry, "register CHURN-CANCEL view=\(Self.id(view)) key=\(currentKey) — host navigator reparented, preserving state")
        }
        return
      } else {
        heroLog(HeroLog.registry, "register key-changed during defer view=\(Self.id(view)) oldKey=\(pending.key) newKey=\(currentKey) — committing old unregister inline")
        pendingUnregisters.removeValue(forKey: viewId)
        commitUnregister(view: pending.view, key: pending.key, baseline: pending.baseline, returnFlightEnabled: pending.returnFlightEnabled)
        // Fall through to regular register for the new key.
      }
    }

    // ObjectIdentifier is just the memory address. Fabric recycles
    // RCTViewComponentView instances, and once a recycled view is dealloc'd its
    // address can be reused for a fresh component — logically new but sharing the
    // dead view's id, so any `currentlyFlying` / `alreadyFlighted` /
    // `pendingFlights` state keyed by it is stale and must be cleared.
    //
    // Symptom otherwise: after a few tap→back→tap cycles a stale `currentlyFlying`
    // entry (whose `dest` was dealloc'd before `onAllDone` removed it) survives,
    // and `pollOnce`'s duplicate-suppression aborts the new flight — just a fade,
    // no hero, indefinitely.
    //
    // Runs AFTER the churn-cancel check above, so a genuine reparent doesn't clear
    // these — only true new-view registrations.
    currentlyFlying.remove(viewId)
    alreadyFlighted.remove(viewId)
    pendingFlights.removeValue(forKey: viewId)
    pendingInPlace.removeValue(forKey: viewId)

    let key = currentKey
    var bucket = live[key] ?? []
    bucket.removeAll { $0.value == nil || $0.value === view }

    // Prefer the most recently-registered twin still ATTACHED to a window.
    // Without this, rapid push/pop cycles can leave a stale outgoing view in the
    // bucket whose `captureSnapshot()` returns nil, silently aborting the flight.
    let twin = bucket.reversed().first(where: {
      guard let v = $0.value else { return false }
      return v.contentView.window != nil
    })?.value
    bucket.append(WeakBox(view))
    live[key] = bucket

    heroLog(HeroLog.registry, "register view=\(Self.id(view)) key=\(key) bucketSize=\(bucket.count) twin=\(twin.map { Self.id($0) } ?? "nil") sameWindow=\(twin.map { $0.contentView.window === view.contentView.window } ?? false)")

    if let twin = twin, twin !== view {
      runTwinFlight(source: twin, dest: view)
      return
    }

    // SEPARATE-WINDOW REAPPEARANCE (e.g. core `<Modal>` dismiss): a source hero
    // for this key already unregistered this matching window and is parked in
    // `recentlyUnregistered` awaiting the match-pass back-flight. The view
    // registering now is that flight's DESTINATION — the underlying list cell
    // re-attaching after the modal's UIWindow was torn down. Hide it the instant
    // it attaches, in THIS synchronous turn, so it never paints at its resting
    // position for the frame or two before `runMatchPass` adds the overlay;
    // otherwise the revealed cell flashes at the bottom and the snapshot then
    // appears at the (top) modal source position — reading as a "teleport" to the
    // top. The match-pass keeps it hidden under the landing overlay (and
    // `pollOnce`'s timeout un-hides it if no flight lands, so it's never stranded).
    //
    // Skip when the parked source is this SAME instance: a host-navigator reparent
    // churn the match-pass ignores (`matchPass skip same-id churn`), so hiding here
    // would leave it hidden with no flight to reveal it.
    if let pendingSource = recentlyUnregistered[key],
       pendingSource.sourceViewId != ObjectIdentifier(view) {
      view.setHiddenForFlight(true)
    }

    pendingKeys.insert(key)
    scheduleMatchPass()
  }

  /// Mark `view`'s back-transition as owned by an interactive return controller
  /// (`InteractiveModalReturn`/`InteractiveStackPop`). Reuses `alreadyFlighted`
  /// so the deferred `commitUnregister` takes its source-already-flighted
  /// early-return instead of starting a duplicate back-flight.
  func markInteractivelyHandled(_ view: SharedHeroViewImpl) {
    alreadyFlighted.insert(ObjectIdentifier(view))
  }

  /// Reverse `markInteractivelyHandled` when an interactive return is cancelled
  /// (sheet snapped back), so a future genuine dismiss isn't suppressed.
  func unmarkInteractivelyHandled(_ view: SharedHeroViewImpl) {
    alreadyFlighted.remove(ObjectIdentifier(view))
  }

  func unregister(_ view: SharedHeroViewImpl) {
    // CHURN-DEFER: defer the real unregister work one tick. If the SAME view
    // re-registers within the tick (host-navigator reparent — see
    // `pendingUnregisters`), `register` pulls this entry out and the commit is a
    // no-op; otherwise the async block runs the real unregister.
    //
    // The one-tick delay is harmless for every legitimate consumer:
    //  - Forward-push end-of-push unmount: the LIST screen is already off-window
    //    when RNS tears it down, and `alreadyFlighted` still short-circuits the
    //    unregister-twin fast path.
    //  - Pop: the back-flight queues one tick later, invisible across the
    //    many-tick pop animation.
    //  - In-place match: same as pop.
    let viewId = ObjectIdentifier(view)
    let key = Self.key(for: view)
    // Already pending for this view → leave the entry (same key/view, idempotent).
    if pendingUnregisters[viewId] == nil {
      // Capture the in-place baseline NOW, while the stash + last stable frame
      // are valid. `prepareToLeaveWindow` (willMoveToWindow:) just refreshed the
      // bitmap; a later capture in the churn-cancel branch would miss it if
      // Fabric recycles the component (InPlaceToggle). Use `inPlaceBaselineSnapshot()`
      // (not `captureOrCachedSnapshot()`) so the SOURCE rect comes from the
      // layout-metrics-derived stable frame, not a torn mid-toggle capture —
      // otherwise the flight starts 100pt off (small box at the large origin).
      let baseline = view.inPlaceBaselineSnapshot()
      pendingUnregisters[viewId] = PendingUnregister(view: view, key: key, baseline: baseline, returnFlightEnabled: view.config.returnFlightEnabled)
    }
    heroLog(HeroLog.registry, "unregister DEFER view=\(Self.id(view)) key=\(key) baseline=\(pendingUnregisters[viewId]?.baseline?.settledFrame.debugDescription ?? "nil") pendingCount=\(pendingUnregisters.count)")
    DispatchQueue.main.async { [weak self, weak view] in
      guard let self = self else { return }
      let pending = self.pendingUnregisters.removeValue(forKey: viewId)
      // nil → register() cancelled the churn. No-op.
      guard let pending = pending else { return }
      // Pass the ORIGINAL key (captured at unregister time), not a recomputed
      // `Self.key(for: view)`: config may have been mutated since (e.g.
      // `prepareForRecycle` resets `config = SharedHeroConfig()` right after
      // `unregister(self)`), which would yield a fresh "default::" and miss the
      // live bucket entry.
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

  /// Real unregister logic, run one tick after the initial call — see
  /// `unregister(_:)` for the churn rationale. `key` is the `namespace::id`
  /// captured at the original call; deliberately NOT recomputed via
  /// `Self.key(for: view)`, whose config may have been mutated since (e.g. by
  /// `prepareForRecycle`).
  private func commitUnregister(view: SharedHeroViewImpl, key: String, baseline: HeroSnapshot? = nil, returnFlightEnabled: Bool = true) {
    heroLog(HeroLog.registry, "unregister COMMIT view=\(Self.id(view)) key=\(key)")
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
      // The unregistering view was the SOURCE of a recent twin-flight (typically
      // the list-side hero whose host screen RNS just tore down after a forward
      // push). Refresh the registry cache before returning so a future forward
      // flight has a snap to fall back to if the re-registered source's live
      // capture momentarily returns nil. Cache writes from unregister are
      // restricted to this branch: the other branch handles detail-side teardown,
      // whose snaps would CORRUPT the key's cache (a future forward flight would
      // fly the destination's bitmap from its position — "no flight").
      if let snap = view.captureOrCachedSnapshot() {
        lastKnownSnapshots[key] = snap
      }
      return
    }

    // Opt-out: `returnFlightEnabled = false` → quiet teardown, never a
    // return/back-flight on unmount. Used by the core `<Modal>` example whose
    // dismiss slides DOWN, carrying the hero off-screen; a back-flight here would
    // redundantly fly the off-screen snapshot back up to the list cell after the
    // slide. Bucket entry + in-place watch were cleared above, so nothing else to
    // do. (Captured at the original `unregister` call — config may be reset by the
    // time this deferred commit runs.)
    if !returnFlightEnabled {
      heroLog(HeroLog.registry, "unregister quiet teardown (returnFlightEnabled=false) view=\(Self.id(view)) key=\(key)")
      return
    }

    // `captureOrCachedSnapshot` falls back to the `prepareToLeaveWindow()` stash
    // when the view is already off-window. `?? baseline` is the last resort: on a
    // UIKit-modal DISMISS the detail (source) is torn down off-window and,
    // depending on recycle/teardown ordering, both its live render and view-level
    // stash can be gone by now ("captureSnapshot returned nil (no live & no
    // stash)"). `baseline`, captured at the original `unregister` while the stash
    // was valid, carries the modal-position frame + bitmap we need as the
    // back-flight's SOURCE.
    let snap = view.captureOrCachedSnapshot() ?? baseline

    // Twin back-flight path. Prefer a sibling twin still ATTACHED to the window
    // (dest never detached — native-stack pop with both screens on-window, or a
    // parent navigator that keeps both attached). Else fall back to an OFF-WINDOW
    // twin: the UIKit-modal DISMISS case. RNS keeps the underlying LIST screen
    // (owning the true destination twin) OFF-window for the modal present, and it
    // re-attaches only as the dismiss reveals it. That twin is the SAME instance
    // simply re-attaching — it never re-registers — so neither the twin-on-register
    // path nor the match-pass (keys that newly registered this tick) ever fires,
    // and the back-flight was being silently dropped.
    //
    // Queue against the off-window twin and lean on `pollOnce`'s wall-clock-bounded
    // pre-attach wait (`everAttached` / `attachDeadline`, mirror of the forward
    // modal fix): the poll holds the flight WITHOUT burning the layout-settle
    // budget until the twin re-attaches, then fires once it settles. If the twin
    // is torn down first, the deadline elapses and `pollOnce` un-hides it, so the
    // list thumbnail is never left invisible.
    if let snap = snap,
       let liveTwin = (live[key]?.reversed().first(where: { box in
         guard let v = box.value else { return false }
         return v !== view && v.contentView.window != nil
       }) ?? live[key]?.reversed().first(where: { box in
         guard let v = box.value else { return false }
         return v !== view
       }))?.value {
      // Interactive UIKit-modal (pageSheet) SWIPE-to-dismiss: the gesture slides
      // the whole sheet (and the detail hero) off the bottom under the finger,
      // and React-Navigation unmounts the modal — triggering THIS unregister and
      // back-flight — only AFTER the dismiss completes. By then the LIST is
      // already revealed with its thumbnail settled (the native dismissal reveals
      // it cleanly on its own). A back-flight now hides that settled thumbnail and
      // flies a late, redundant overlay in from the off-screen source — the glitch.
      //
      // Detect via the captured source sitting (mostly) below the screen bottom
      // and SUPPRESS, leaving the dest visible where the sheet already revealed it.
      //
      // Unaffected: the button-dismiss path (`goBack()` unmounts at the START, so
      // the source is captured on-screen / falls back to the on-screen `baseline`
      // and the overlap looks right), and GestureReturn drag-to-dismiss (pops at a
      // moderate offset with the source center still on-screen, so the slingshot
      // fires as before).
      let screenHeight = view.contentView.window?.bounds.height
        ?? liveTwin.contentView.window?.bounds.height
        ?? UIScreen.main.bounds.height
      if snap.frame.midY >= screenHeight {
        heroLog(HeroLog.registry, "back-flight SUPPRESSED (interactive swipe dismiss — source offscreen snapMidY=\(snap.frame.midY) screenH=\(screenHeight)) dest=\(Self.id(liveTwin))")
        // Defensive: don't leave the revealed thumbnail hidden by stale state.
        liveTwin.setHiddenForFlight(false)
        return
      }

      // Record this back-flight's source frame for the NEXT forward push's
      // `destFrameHint` (push/pop symmetry — see `lastFlightSourceFrame`). Cache
      // the SETTLED frame, not the possibly-transformed `snap.frame`: after a
      // drag-to-dismiss the snap's frame holds the drag offset, whereas the next
      // push's dest lays out at the natural position the hint must match.
      lastFlightSourceFrame[key] = snap.settledFrame != .zero ? snap.settledFrame : snap.frame
      let twinAttached = liveTwin.contentView.window != nil
      heroLog(HeroLog.registry, "unregister-twin fire source=\(Self.id(view)) dest=\(Self.id(liveTwin)) twinAttached=\(twinAttached) cached=\(lastFlightSourceFrame[key]?.debugDescription ?? "nil")")
      alreadyFlighted.insert(ObjectIdentifier(view))
      liveTwin.setHiddenForFlight(true)
      // No `destFrameHint` for the back-flight: the only returns still reaching
      // this path are NON-interactive, TRANSFORM-driven (button pop or modal
      // button-dismiss), for which `settledWindowFrame()` already neutralises the
      // in-progress parallax and reports the correct resting rect — so `pollOnce`
      // fires on the freshly-sampled settled frame. (Interactive left-edge
      // swipe-backs, fast OR slow, are now owned by `InteractiveStackPop`, which
      // marks the detail `interactivelyHandled` so this branch never runs for
      // them; the stale hint it used to pin was the fast-swipe jump-to-top cause.)
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
    // Grab the previous flight's source frame BEFORE overwriting it below. By
    // push/pop symmetry it's the EXPECTED LANDING RECT of the current dest:
    // consecutive flights for a key swap roles (push list→detail, pop
    // detail→list), so the previous source's window frame is exactly where this
    // dest should land. Passed to `pollOnce` as `destFrameHint` so the poll
    // ignores transient mid-relayout `settled` reads and waits for the real one.
    let destFrameHint = lastFlightSourceFrame[key]

    // Source snapshot resolution order:
    //  1. Live `captureSnapshot()` (itself falling back to the view-level stash).
    //  2. Registry-level `lastKnownSnapshots[key]` — when the view's stash is also
    //     lost (recycled / briefly dealloc'd by Fabric).
    // Without the registry fallback the path silently aborts and the user sees a
    // fade with no hero — the "tap A → back → tap A → ... fades after a few
    // cycles" regression.
    let liveSnap: HeroSnapshot
    if let live = source.captureSnapshot() {
      liveSnap = live
      lastKnownSnapshots[key] = live
    } else if let cached = lastKnownSnapshots[key] {
      heroLog(HeroLog.registry, "runTwinFlight using registry-cached snap source=\(Self.id(source)) key=\(key)")
      liveSnap = cached
    } else {
      heroLog(HeroLog.registry, "runTwinFlight abort: source snapshot is nil and no cache source=\(Self.id(source)) key=\(key) inWindow=\(source.contentView.window != nil) bounds=\(source.contentView.bounds)")
      return
    }

    // `runTwinFlight` only fires on the FORWARD push (new dest registers while
    // the source twin is still attached). By now the push animation has STARTED —
    // RNS drives `view.transform = translation(-0.3 * W, 0)` parallax on the
    // previous screen — so `source.windowFrame()` (via `convert(_:to:window)`,
    // which respects ancestor transforms) reports a position shifted LEFT by the
    // parallax progress.
    //
    // Using `liveSnap.frame` as the start rect would place the overlay at that
    // parallax-shifted spot, not the natural source the user tapped. On `ArcPath`
    // (default slide-from-right, not `fade`) this reads as "the hero slides in
    // from the LEFT": the start sits at x ≈ naturalX - 0.3 * W and the arc carries
    // it to the dest center.
    //
    // `settledFrame` comes from the layer chain's `position` (NOT `transform`), so
    // it's the NATURAL window rect regardless of in-progress parallax. Rebuild
    // `snap` so FlightEngine starts at the natural source position.
    //
    // (The back-pop unregister-twin path below intentionally keeps `snap.frame`:
    // it reflects user transforms like `<Animated.View translateY={dragOffset}>`
    // so the back-flight starts from the dragged position. By `prepareToLeaveWindow`
    // the pop animation is done and RNS has reset the screen transform to identity,
    // so user transforms are the only `frame` vs `settledFrame` delta.)
    let snap = HeroSnapshot(
      image: liveSnap.image,
      frame: liveSnap.settledFrame != .zero ? liveSnap.settledFrame : liveSnap.frame,
      settledFrame: liveSnap.settledFrame,
      cornerRadius: liveSnap.cornerRadius,
      backgroundColor: liveSnap.backgroundColor
    )

    // Record this flight's source frame for the NEXT flight's hint. Use the
    // SETTLED (untransformed) frame so a future flight whose dest lays out at the
    // natural position can match it — see the unregister-twin drag-dismiss note.
    lastFlightSourceFrame[key] = snap.settledFrame != .zero ? snap.settledFrame : snap.frame
    heroLog(HeroLog.registry, "runTwinFlight source=\(Self.id(source)) dest=\(Self.id(dest)) sourceFrame=\(source.windowFrame()) liveFrame=\(liveSnap.frame) settledFrame=\(liveSnap.settledFrame) destFrameHint=\(destFrameHint?.debugDescription ?? "nil")")

    // INTERACTIVE EDGE-SWIPE POP.
    //
    // This path fires for BOTH directions: forward push (new dest registers with
    // its twin attached) AND native-stack pop (the screen below re-attaches and
    // re-registers, finding the leaving detail as its twin). For an interactive
    // left-edge swipe-back the time-driven flight below is wrong: it fires at
    // swipe-START, ignores the finger, and on a slow swipe its 2 s poll times out
    // mid-gesture and lands on the still-sliding parallax ("flies to the wrong
    // position").
    //
    // If `source` is a detail hero with an armed interactive pop controller (from
    // its push) AND the nav controller reports an INTERACTIVE transition (the
    // swipe, NOT a programmatic push / button pop), hand the back-transition to
    // `InteractiveStackPop` and SKIP the time-driven flight + the re-arm below.
    // The controller retargets to the re-entering `dest` twin and drives the
    // overlay from the finger into the list thumbnail. Forward pushes and button
    // pops return false and keep their normal morph flight.
    //
    // NOTE: `lastFlightSourceFrame[key]` is recorded ABOVE so the next forward
    // push still gets the correct symmetric hint even when we defer this flight.
    if InteractiveStackPop.shared.tryAdoptInteractivePop(detail: source, dest: dest, sourceSnap: snap) {
      heroLog(HeroLog.registry, "runTwinFlight DEFERRED to InteractiveStackPop (interactive pop) source=\(Self.id(source)) dest=\(Self.id(dest))")
      return
    }

    alreadyFlighted.insert(ObjectIdentifier(source))
    // Hide the DESTINATION now — Fabric is about to mount/lay it out and we don't
    // want it to flash before the overlay lands. DON'T hide the source yet:
    // doing so commits a "source disappears" frame before the snapshot is ready
    // (dest still needs layout). The source is hidden in `tryFire(...)` in the
    // same tick the overlay is added, so CATransaction batches both and the
    // source→snapshot swap has no blank gap.
    dest.setHiddenForFlight(true)
    queuePendingFlight(snap: snap, source: source, dest: dest, destFrameHint: destFrameHint)

    // Arm interactive return tracking. Both controllers are cheap to arm per twin
    // flight and mutually exclusive by context — each stands down once `dest`
    // settles on-window if the context isn't theirs:
    //   * `InteractiveModalReturn` owns swipe-DOWN dismiss of sheet modals
    //     (`presentation: 'modal'`/`'formSheet'`).
    //   * `InteractiveStackPop` owns the left-edge swipe-BACK pop of a native
    //     stack (the parallax-slide the time-driven back-flight couldn't track).
    //     On activation it marks the detail `interactivelyHandled` so the
    //     end-of-pop `commitUnregister` back-flight stands down and we own it.
    InteractiveModalReturn.shared.arm(detail: dest, twin: source)
    InteractiveStackPop.shared.arm(detail: dest, twin: source)
  }

  /// Queue a flight for `dest` once its layout is stable. `pollOnce(_:)` runs
  /// once per runloop tick (chained `DispatchQueue.main.async`) and fires only
  /// when two consecutive samples agree.
  ///
  /// Two samples from DIFFERENT ticks are required because:
  /// 1. On native-stack pop the re-attached dest's `bounds` are preserved (settled
  ///    reads non-zero immediately) but Fabric may still be committing ancestor
  ///    layer positions — firing on the first sample lands at the wrong cell.
  /// 2. On forward push the fresh dest's `bounds` start at zero, failing the
  ///    `!= .zero` guard; we record the first valid sample and fire on the next
  ///    matching one.
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
    heroLog(HeroLog.registry, "queuePendingFlight dest=\(Self.id(dest)) source=\(source.map { Self.id($0) } ?? "nil") destFrameHint=\(destFrameHint?.debugDescription ?? "nil")")
    schedulePoll(dest: dest)
  }

  /// Called synchronously from `SharedHeroViewImpl.didUpdateLayoutMetrics()`
  /// (Fabric's `updateLayoutMetrics:`) and from `didMoveToWindow(_:)` on attach.
  /// In-place fast path: if the view is watched for an in-place resize
  /// (`pendingInPlace`) and its NEW frame differs in SIZE from the baseline, fire
  /// the flight RIGHT NOW — in the same runloop turn the layout applies — so the
  /// new state is committed already hidden and never renders uncovered.
  ///
  /// Fixes the "tap → flash destination state → rewind to source → animate"
  /// glitch: the async `pollInPlace` fallback hides the view a tick AFTER the new
  /// layout has committed and rendered; reacting on the layout/attach event
  /// closes that window.
  ///
  /// Safety:
  ///   * Reads `settledWindowFrame()` (not a shim), which returns `.zero` for
  ///     degenerate bounds, so a not-yet-laid-out attach bails and `pollInPlace`
  ///     picks it up — never fire on a transient frame.
  ///   * Transform-aware, so an in-progress parallax can't inflate/shift the rect;
  ///     and we key off SIZE only, which a reparent never changes. Navigation
  ///     flights have no `pendingInPlace` entry, so they're untouched.
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
    heroLog(HeroLog.registry, "in-place fire (sync layout) view=\(Self.id(view)) baseline=\(b) dest=\(dest)")
    // Hide + add the overlay in THIS layout transaction so CoreAnimation batches
    // the hide with the new-layout commit — the destination state never appears
    // uncovered. Pass `dest` as the override since we just resolved it.
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
  /// Watches a churn-cancelled view (`pendingInPlace`) for a genuine layout
  /// change: fires a self-flight the moment it settles at a frame differing from
  /// the baseline; gives up (treats it as a reparent) after `inPlaceMaxAttempts`
  /// ticks. Usually `notifyLayoutReady` fires first and clears the entry, so this
  /// no-ops; it's a safety net for paths where neither event delivers a usable
  /// on-window frame in time — but it hides the view a tick LATE, so flights
  /// through here can show the one-frame destination flash the sync path avoids.
  private func pollInPlace(view: SharedHeroViewImpl) {
    let viewId = ObjectIdentifier(view)
    guard var p = pendingInPlace[viewId] else { return }

    let settled = view.settledWindowFrame()
    let attached = view.contentView.window != nil

    if attached, settled != .zero {
      let b = p.baseline.settledFrame
      let tol = inPlaceChangeThreshold
      // SIZE change only — deliberately NOT origin. A push parallax-shifts a
      // sibling's origin by up to ~30% of screen width, and `settledWindowFrame`
      // can transiently report that; keying off position would read it as an
      // in-place move and fly a ghost snapshot (the ArcPath regression). A genuine
      // in-place transition (InPlaceToggle 120pt→320pt) always changes intrinsic
      // SIZE, which no parallax does.
      let changed =
        abs(settled.width - b.width) > tol ||
        abs(settled.height - b.height) > tol
      if changed {
        pendingInPlace.removeValue(forKey: viewId)
        // A flight may have started meanwhile (rapid toggling). Bail rather than
        // stacking overlays — the view is already at its real layout, so the worst
        // case is the latest toggle lands without animation.
        if currentlyFlying.contains(viewId) {
          heroLog(HeroLog.registry, "in-place skip (already flying) view=\(Self.id(view))")
          return
        }
        heroLog(HeroLog.registry, "in-place fire view=\(Self.id(view)) baseline=\(b) settled=\(settled)")
        // Fire DIRECTLY (not via `queuePendingFlight`): we've already verified the
        // settled frame, so the poll loop would only add a one-tick gap between
        // hiding the view and adding the overlay. A navigation flight masks that
        // gap with the screen transition, but an in-place morph has none, so it
        // shows as a one-frame blank (the "image blinks" report). Same-tick hide +
        // overlay removes the blink.
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
      heroLog(HeroLog.registry, "in-place discard (no resize → treated as reparent) view=\(Self.id(view)) settled=\(settled)")
      return
    }
    pendingInPlace[viewId] = p
    scheduleInPlaceCheck(view: view)
  }

  /// Tolerance (pt) for matching a freshly-sampled `settled` against the cached
  /// `destFrameHint`. Sub-pixel jitter from Fabric's layout rounding is fine —
  /// only off-by-padding (≥ a few pt) means the layout is still in flux.
  private let hintMatchTolerance: CGFloat = 4

  /// Single polling tick. Fires when:
  ///   • A `destFrameHint` exists and `settled` matches it within
  ///     `hintMatchTolerance` — the strong path for every back-flight (and every
  ///     forward push after the first cycle); deliberately discards a "stable but
  ///     wrong" sample pair.
  ///   • No hint (first flight for this key) and two consecutive ticks read the
  ///     same non-zero `settled` — the legacy bootstrap stability check.
  /// Otherwise the sample is recorded and another poll scheduled.
  private func pollOnce(dest: SharedHeroViewImpl) {
    let key = ObjectIdentifier(dest)
    guard var pending = pendingFlights[key] else { return }

    let settled = dest.settledWindowFrame()
    let attached = dest.contentView.window != nil
    let isReady = attached && settled != .zero

    if attached {
      pending.everAttached = true
    } else if !pending.everAttached {
      // Dest queued this flight before attaching, and still hasn't. A UIKit modal
      // (RNS `presentation: 'modal'`/`'transparentModal'`) keeps its content
      // off-window until the present completes, past the normal settle budget.
      // Keep polling WITHOUT consuming `attemptsLeft` so we fire the instant the
      // modal attaches the hero. Bounded by a wall-clock deadline so a dest torn
      // down before it ever attaches unhides instead of staying hidden.
      if let deadline = pending.attachDeadline, CACurrentMediaTime() > deadline {
        pendingFlights.removeValue(forKey: key)
        heroLog(HeroLog.registry, "gave up waiting for dest to ATTACH dest=\(Self.id(dest))")
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
      // Strong path (forward push & match-pass): trust the cached symmetric rect
      // over a transient `settled` — wait for `settled` to agree with the hint so
      // an early/mislaid sample can't fire.
      canFire = isReady && matchesHint
    } else {
      // No hint: first-ever flight for this key OR a back-flight (button pop /
      // modal button-dismiss). Fire on the legacy two-consecutive-samples check
      // and land at the freshly-sampled `settled` — correct for these
      // transform-driven returns.
      canFire = isReady && pending.lastSampledFrame == settled
    }

    if canFire {
      // Suppress duplicate firing — if a previous flight is still animating, drop
      // this one so we don't stack overlays / re-hide the source mid-flight.
      if currentlyFlying.contains(key) {
        heroLog(HeroLog.registry, "DUPLICATE FLIGHT SUPPRESSED dest=\(Self.id(dest))")
        pendingFlights.removeValue(forKey: key)
        pending.source?.setHiddenForFlight(false)
        dest.setHiddenForFlight(false)
        return
      }
      pendingFlights.removeValue(forKey: key)
      currentlyFlying.insert(key)
      heroLog(HeroLog.registry, "flight fire dest=\(Self.id(dest)) sampledSettled=\(settled) destVisible=\(dest.windowFrame()) hint=\(pending.destFrameHint?.debugDescription ?? "nil") sourceSnap=\(pending.snap.frame) sourceSettled=\(pending.snap.settledFrame) attemptsUsed=\(maxLayoutAttempts - pending.attemptsLeft)")
      // One-shot layer-chain dump for the dest, to correlate a wrong `settled`
      // against actual ancestor positions/transforms — e.g. which ancestor still
      // has a non-identity transform we failed to compensate for.
      dest.dumpLayerChain(prefix: "flight-fire-dest")
      if let src = pending.source {
        src.dumpLayerChain(prefix: "flight-fire-source")
      }
      // Hide source + add the overlay snapshot in the SAME tick so they commit
      // together — no blank between the source disappearing and the overlay
      // taking its place.
      //
      // We deliberately do NOT hide OTHER heroes in the namespace. An earlier
      // version did ("auxiliaryHidden") so the flying snapshot would "own" the
      // screen during the transition, but it broke screens with multiple heroes
      // far from the flight path (e.g. BasicImageHero: tapping one image made
      // every other vanish under its caption during the flight, and again on the
      // back-flight as the list re-entered). The overlay is already on a
      // window-level layer above everything; the screen transition does the rest,
      // and leaving siblings visible matches Material container-transform.
      pending.source?.setHiddenForFlight(true)
      // Pin the landing rect to the value we just verified so FlightEngine doesn't
      // re-read `settledWindowFrame()` and pick up a different sample a tick later.
      // Prefer the hint when present (more authoritative — stable across a full
      // push/pop cycle for this key); a back-flight has none and lands at the
      // freshly-sampled `settled`.
      let landingFrame: CGRect = pending.destFrameHint ?? settled
      heroLog(HeroLog.flight, "landing rect dest=\(Self.id(dest)) usedRect=\(landingFrame) source=\(pending.destFrameHint != nil ? "settled-hint" : "live-settled") sampledSettled=\(settled) destLive=\(dest.windowFrame()) destSettled=\(dest.settledWindowFrame())")
      // Capture `key` by value (ObjectIdentifier is a value type) rather than
      // recomputing `ObjectIdentifier(dest)` in the completion. If `dest` is
      // dealloc'd before it fires (navigate away mid-flight, Fabric tears the view
      // down), a `[weak dest]` closure would early-return and leak the
      // `currentlyFlying` entry — blocking every future flight landing at the same
      // address.
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
      // Last-ditch fallback: pick the best landing rect. Prefer the current
      // `settled` (freshest layout) over the cached `destFrameHint` — if Fabric
      // had 2 s to converge and `settled` still doesn't match, the dest's layout
      // has likely genuinely changed (orientation, list reorder, scroll) and the
      // hint is STALE. Trusting `settled` lands at the real position; trusting the
      // hint would land at the OLD one then snap to the new on completion (the
      // failure mode that prompted this function). Hint is still used when
      // `settled` is unusable (dest briefly off-window), better than giving up.
      let landing: CGRect?
      if attached, settled != .zero {
        landing = settled
      } else if let hint = pending.destFrameHint, attached {
        landing = hint
      } else {
        landing = nil
      }
      if let landing = landing {
        heroLog(HeroLog.registry, "poll timeout: firing dest=\(Self.id(dest)) landing=\(landing) lastSettled=\(settled) destLive=\(dest.windowFrame()) hint=\(pending.destFrameHint?.debugDescription ?? "nil")")
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
      heroLog(HeroLog.registry, "gave up waiting for dest layout dest=\(Self.id(dest))")
      pending.source?.setHiddenForFlight(false)
      dest.setHiddenForFlight(false)
      return
    }
    pendingFlights[key] = pending
    schedulePoll(dest: dest)
  }

  private let maxLayoutAttempts: Int = 120

  /// Wall-clock seconds to wait for a queued flight's dest to attach for the
  /// FIRST time (see `PendingFlight.attachDeadline`). Generous enough for a UIKit
  /// modal present (which holds the hero off-window for the present animation)
  /// while still bounding a dest that never attaches.
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

      // Churn guard (defense-in-depth — see `pendingUnregisters`): if the dest is
      // the SAME instance that just unregistered (host navigator reparenting the
      // subtree), snap and dest came from the same view, so a flight here would
      // animate the list image onto itself — the "ghost image over the detail
      // screen" ArcPath symptom. Skip silently.
      if entry.sourceViewId == ObjectIdentifier(dest) {
        heroLog(HeroLog.registry, "matchPass skip same-id churn key=\(key) dest=\(Self.id(dest))")
        continue
      }

      let snap = entry.snap
      let destFrameHint = lastFlightSourceFrame[key]
      // See `unregister(_:)` for why we cache `settledFrame`, not `frame`.
      lastFlightSourceFrame[key] = snap.settledFrame != .zero ? snap.settledFrame : snap.frame
      heroLog(HeroLog.registry, "matchPass fire key=\(key) dest=\(Self.id(dest)) destFrameHint=\(destFrameHint?.debugDescription ?? "nil")")
      dest.setHiddenForFlight(true)

      // FAST PATH for the separate-window reappearance (core `<Modal>` dismiss):
      // the dest (list) hero is already attached at its resting position by the
      // time the match-pass runs — the list never moved while the modal owned its
      // own UIWindow, so the freshly-sampled `settled` already agrees with the
      // cached `destFrameHint`. Routing through `queuePendingFlight` would insert
      // one or two poll-loop ticks between hiding the dest above and the overlay's
      // first paint; on an instant-dismiss modal (window already gone) that's a
      // visible blank, making the snapshot pop in at the (top) source position
      // several frames late. Firing synchronously commits the hide and the first
      // overlay frame in the SAME tick, at the earliest moment the dest exists, so
      // the hand-off reads as continuous.
      //
      // Strictly gated so every OTHER match-pass keeps its poll behaviour: only
      // short-circuit when a hint exists AND live `settled` matches it within
      // tolerance. A first-ever match (no hint) or a resizing in-place swap
      // (settled won't match the stale hint) fall through to `queuePendingFlight`.
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
          heroLog(HeroLog.registry, "matchPass fire SYNC dest=\(Self.id(dest)) landing=\(hint) settled=\(settled)")
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
