package com.sharedhero

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.lang.ref.WeakReference

/**
 * Process-wide registry of mounted [SharedHeroView]s; drives the router-
 * agnostic match logic. Main-thread only.
 *
 * Two trigger paths:
 * 1. **Twin appears while another is still live** — native-stack push/pop on
 *    react-native-screens, where both screens' heroes are window-attached
 *    during the slide. Snapshot the existing twin the moment the new one
 *    registers (source frame recorded *before* the navigator moves it), then
 *    fly on the next frame once the new twin is laid out.
 * 2. **Existing twin unregisters, then a new one mounts within one frame** —
 *    state-driven in-place transitions: one hero unmounts and is immediately
 *    replaced by a sibling with the same id.
 */
object HeroRegistry {
  private val live = mutableMapOf<String, MutableList<WeakReference<SharedHeroView>>>()
  private val recentlyUnregistered = mutableMapOf<String, PendingSource>()
  private val pendingMatchKeys = mutableSetOf<String>()
  /** Identity hashes of views that already participated in a twin-flight; we skip the in-place path for them when they later unregister. */
  private val alreadyFlighted = mutableSetOf<Int>()
  /** Flights queued waiting for the destination's first non-zero layout. */
  private val pendingFlights = mutableMapOf<Int, PendingFlight>()
  /**
   * Last known-good source snapshot per `(namespace, id)` key, populated when
   * we queue a flight from a non-blank bitmap. Last-resort fallback when an
   * unregistering view offers neither a live render nor a usable stash (e.g. an
   * InPlaceToggle destination whose stash never refreshed). Mirrors iOS's
   * `lastKnownSnapshots`; without it a later in-place toggle flies an
   * invisible/blank overlay or skips the overlay entirely.
   */
  private val lastKnownSnapshots = mutableMapOf<String, HeroSnapshot>()
  private val handler = Handler(Looper.getMainLooper())
  private var matchScheduled = false

  private fun HeroSnapshot.hasBitmap(): Boolean = bitmap != null

  /**
   * Source pending an in-place match. Keeps the source's identity hash so the
   * match logic can detect "new dest is the SAME instance that just
   * unregistered" — a host-navigator reparent (detach+reattach within a tick)
   * that must NOT fly a view onto itself (the iOS "same-id churn" ghost bug).
   */
  private data class PendingSource(val snapshot: HeroSnapshot, val sourceViewId: Int)

  /**
   * Flight queued waiting for the destination's first layout pass.
   *
   * [inPlace] marks a same-screen state toggle (same-id unmount→remount, no
   * host transition). These fire SYNCHRONOUSLY from [notifyLayoutReady] —
   * overlay added in the same frame the layout lands — since there's no screen
   * transition to mask the one-frame gap the deferred path leaves.
   */
  private data class PendingFlight(
    val snapshot: HeroSnapshot,
    val source: WeakReference<SharedHeroView>?,
    val inPlace: Boolean = false,
  )

  fun register(view: SharedHeroView) {
    // Fabric recycles RCT view instances, so a `System.identityHashCode` can
    // belong to a prior lifecycle (GC'd address reused, or a recycled view
    // re-registering). Clear any state keyed by it so this registration starts
    // fresh. Otherwise `alreadyFlighted` keeps a stale entry and the view's
    // next unregister takes the "already flighted, skip" branch — back-flight
    // never fires.
    val viewId = System.identityHashCode(view)
    alreadyFlighted.remove(viewId)
    pendingFlights.remove(viewId)

    val key = keyFor(view)
    val bucket = live.getOrPut(key) { mutableListOf() }
    bucket.removeAll { it.get() == null || it.get() === view }

    // Prefer the most recently-registered twin still ATTACHED to a window.
    // Without this, rapid push/pop cycles leave a stale outgoing view in the
    // bucket whose `captureSnapshot()` bails (or returns empty) — the flight
    // silently fails to render.
    val twin = bucket.asReversed().firstNotNullOfOrNull { ref ->
      val v = ref.get()
      if (v != null && v.isAttachedToWindow) v else null
    }
    bucket.add(WeakReference(view))

    if (twin != null && twin !== view) {
      runTwinFlight(source = twin, dest = view)
      return
    }

    // No live twin, but a same-key twin unregistered earlier this tick. On
    // Android (Fabric doesn't recycle our view) an in-place toggle (e.g.
    // InPlaceToggle: same `id`, different React `key`, 120pt ↔ 320pt) unmounts
    // the old hero and mounts a *brand new* dest, and Fabric runs the Remove
    // before the Insert — so by now the old twin has detached and the
    // twin-on-register fast path above missed.
    //
    // Falling through to the async match-pass (as we used to) renders the fresh
    // dest at full size before the next-tick pass hides it (the "hard snap"),
    // then shows the overlay a tick later (a visible blank) — and there's no
    // host transition to mask either gap.
    //
    // Handle it synchronously: hide the dest NOW (inside `onAttachedToWindow`,
    // before its first draw, so it never renders uncovered) and arm an in-place
    // flight that fires the instant Fabric applies the new layout this same
    // frame (see `notifyLayoutReady`). Mirrors iOS's synchronous in-place path.
    //
    // `sourceViewId != viewId` skips a reparent that detached+reattached the
    // SAME instance within a tick — flying a view onto itself paints a phantom
    // snapshot over the dest (the iOS same-id churn ghost bug).
    val recent = recentlyUnregistered[key]
    if (recent != null && recent.sourceViewId != viewId) {
      recentlyUnregistered.remove(key)
      pendingMatchKeys.remove(key)
      // Source snapshot came from the now-detached outgoing view. If its bitmap
      // is blank (the repeat-toggle failure: the previous flight's dest became
      // this source without refreshing a real stash) fall back to the last
      // known-good snap for this key so we fly a visible bitmap.
      val sourceSnap = resolveInPlaceSource(recent.snapshot, key)
      Log.d(
        TAG,
        "register in-place fire key=$key dest=${id(view)} " +
          "recentBitmap=${recent.snapshot.bitmap?.let { "${it.width}x${it.height}" } ?: "null"} " +
          "recentBlank=${isLikelyBlank(recent.snapshot.bitmap)} " +
          "usedFallback=${sourceSnap !== recent.snapshot} " +
          "sourceRect=${sourceSnap.rect}",
      )
      view.setHiddenForFlight(true)
      queuePendingFlight(sourceSnap, source = null, dest = view, inPlace = true)
      return
    }

    pendingMatchKeys.add(key)
    scheduleMatchPass()
  }

  fun unregister(view: SharedHeroView) {
    val key = keyFor(view)
    live[key]?.let { bucket ->
      bucket.removeAll { it.get() === view || it.get() == null }
      if (bucket.isEmpty()) live.remove(key)
    }
    if (alreadyFlighted.remove(System.identityHashCode(view))) {
      // Already played the source of a recent twin-flight; don't re-arm the
      // in-place match path with a now-stale snapshot.
      return
    }

    // `returnFlightEnabled = false`: quiet teardown, no return/back-flight on
    // unmount. Used by the core `<Modal>` example whose dismiss slides the hero
    // off-screen — a back-flight here would redundantly fly a snapshot back up
    // to the list cell after the slide.
    if (!view.config.returnFlightEnabled) {
      Log.d(TAG, "unregister quiet teardown (returnFlightEnabled=false) source=${id(view)} key=$key")
      return
    }

    // `captureOrCachedSnapshot` falls back to the `onDetachedFromWindow` stash
    // if the view is already off-window, so the back-flight survives navigators
    // that unmount the source before the dest re-attaches.
    val snap = view.captureOrCachedSnapshot()
    Log.d(
      TAG,
      "unregister source=${id(view)} key=$key " +
        "bitmap=${snap?.bitmap?.let { "${it.width}x${it.height}" } ?: "null"} " +
        "blank=${isLikelyBlank(snap?.bitmap)} rect=${snap?.rect}",
    )

    // Fast path: a sibling twin is still attached — fire the back-flight now,
    // no match-pass tick. Covers navigators that keep both screens attached
    // (the dest won't re-register, so the twin-on-register path can't fire).
    if (snap != null) {
      val liveTwin = live[key]?.asReversed()?.firstNotNullOfOrNull { ref ->
        val v = ref.get()
        if (v != null && v !== view && v.isAttachedToWindow) v else null
      }
      if (liveTwin != null) {
        Log.d(TAG, "unregister-twin fire source=${id(view)} dest=${id(liveTwin)}")
        alreadyFlighted.add(System.identityHashCode(view))
        liveTwin.setHiddenForFlight(true)
        queuePendingFlight(snap, view, liveTwin)
        return
      }
    }

    if (snap != null) {
      recentlyUnregistered[key] = PendingSource(snap, System.identityHashCode(view))
    }
    pendingMatchKeys.add(key)
    scheduleMatchPass()
  }

  /** Called when an already-registered view changed its `(id, namespace)`. */
  fun notifyConfigChanged(view: SharedHeroView) {
    val key = keyFor(view)
    val bucket = live[key]
    if (bucket == null || bucket.none { it.get() === view }) {
      register(view)
    }
  }

  // MARK: - Twin-register path (covers native-stack push/pop).

  private fun runTwinFlight(source: SharedHeroView, dest: SharedHeroView) {
    val snap = source.captureSnapshot() ?: run {
      Log.d(TAG, "runTwinFlight abort: source snapshot is null source=${id(source)}")
      return
    }
    Log.d(TAG, "runTwinFlight source=${id(source)} dest=${id(dest)} sourceRect=${source.windowRect()}")
    alreadyFlighted.add(System.identityHashCode(source))
    // Hide DEST now so it can't flash visible before layout. Source is hidden
    // later in `tryFire` so its disappearance and the overlay's appearance
    // commit in the same frame — no visible blank.
    dest.setHiddenForFlight(true)
    queuePendingFlight(snap, source, dest)
  }

  /**
   * Queue a flight that fires once [dest] has a non-zero size. Two trigger
   * paths race: [notifyLayoutReady] (called from `SharedHeroView.onLayout`)
   * and the polling fallback in [pollForLayout]. First one to find a valid
   * frame wins.
   */
  private fun queuePendingFlight(
    snap: HeroSnapshot,
    source: SharedHeroView?,
    dest: SharedHeroView,
    inPlace: Boolean = false,
  ) {
    // Remember the last known-good (non-blank) snapshot for this key so a
    // future toggle whose source can't render falls back to it instead of
    // flying an invisible overlay.
    if (snap.hasBitmap() && !isLikelyBlank(snap.bitmap)) {
      lastKnownSnapshots[keyFor(dest)] = snap
    }
    val key = System.identityHashCode(dest)
    pendingFlights[key] = PendingFlight(snap, source?.let { WeakReference(it) }, inPlace)
    if (tryFire(dest, attemptsUsed = 0)) return
    pollForLayout(dest, MAX_LAYOUT_ATTEMPTS)
  }

  private fun isLikelyBlank(bitmap: android.graphics.Bitmap?): Boolean =
    isLikelyBlankBitmap(bitmap)

  /** Called from `SharedHeroView.onSizeChanged`. */
  fun notifyLayoutReady(view: SharedHeroView) {
    val key = System.identityHashCode(view)
    val pending = pendingFlights[key] ?: return
    if (pending.inPlace) {
      // In-place toggle: no host transition to mask a one-frame gap, so fire
      // SYNCHRONOUSLY in this layout pass. We're inside `onSizeChanged` (the
      // view's `layout` pass), so ancestor `left/top/right/bottom` are assigned
      // and `settledWindowRect()` — which the engine uses for the dest, NOT
      // `getLocationInWindow` — is stable. Overlay-in-this-frame means dest
      // hidden, overlay over the source, and the morph all commit together —
      // no snap to dest size, no blank gap.
      tryFire(view, attemptsUsed = 0)
      return
    }
    // Navigation flights: defer one frame so `getLocationInWindow` and any
    // in-progress host transform have a tick to settle.
    handler.post { tryFire(view, attemptsUsed = 0) }
  }

  private fun tryFire(dest: SharedHeroView, attemptsUsed: Int): Boolean {
    val key = System.identityHashCode(dest)
    val pending = pendingFlights[key] ?: return true
    if (!dest.isAttachedToWindow || dest.width <= 0 || dest.height <= 0) {
      return false
    }

    // Resolve the best NON-BLANK source bitmap, in priority order:
    //   1. the captured source snapshot (common case),
    //   2. the DEST's freshly-rendered content — same image for an in-place
    //      toggle, and `renderContentForFlightFallback()` draws it directly so
    //      it ignores the dest's hidden alpha,
    //   3. the per-key last-known-good snapshot.
    // Any non-blank capture is promoted into `lastKnownSnapshots` so future
    // toggles always have a fallback.
    //
    // Matters on a COLD-LAUNCH FIRST toggle: the captured source is blank (the
    // remote <Image> composites a few frames after mount) and there's no prior
    // snapshot, so without this the flight flew an invisible overlay ("blank
    // for a frame, then snap"). Later toggles worked only because the image had
    // painted and `lastKnownSnapshots` was populated by then.
    val destKey = keyFor(dest)
    var snap = pending.snapshot
    var haveContent = snap.hasBitmap() && !isLikelyBlank(snap.bitmap)
    if (haveContent) {
      lastKnownSnapshots[destKey] = snap
    } else {
      val destContent = dest.renderContentForFlightFallback()
      if (destContent?.bitmap != null && !isLikelyBlank(destContent.bitmap)) {
        lastKnownSnapshots[destKey] =
          HeroSnapshot(destContent.bitmap, destContent.rect, destContent.cornerRadius, destContent.backgroundColor)
        val srcRect = if (snap.rect.width() > 0 && snap.rect.height() > 0) snap.rect else destContent.rect
        snap = HeroSnapshot(destContent.bitmap, srcRect, snap.cornerRadius, snap.backgroundColor)
        haveContent = true
      } else {
        val fallback = lastKnownSnapshots[destKey]
        if (fallback?.bitmap != null && !isLikelyBlank(fallback.bitmap)) {
          val srcRect = if (snap.rect.width() > 0 && snap.rect.height() > 0) snap.rect else fallback.rect
          snap = HeroSnapshot(fallback.bitmap, srcRect, snap.cornerRadius, snap.backgroundColor)
          haveContent = true
        }
      }
    }

    // Cold-launch first toggle: source, dest, and prior snapshot are all
    // unpainted. Rather than fly a blank overlay, wait a bounded number of
    // frames for the <Image> to paint — the dest stays hidden meanwhile (source
    // already unmounted) so its size never flashes. `pollForLayout` re-invokes
    // us each frame; once the budget is spent we fire best-effort so we never
    // hang or leave the dest hidden.
    if (!haveContent && pending.inPlace && attemptsUsed < CONTENT_WAIT_ATTEMPTS) {
      return false
    }

    pendingFlights.remove(key)
    Log.d(
      TAG,
      "flight fire dest=${id(dest)} settledRect=${dest.settledWindowRect()} " +
        "attemptsUsed=$attemptsUsed haveContent=$haveContent",
    )
    // Hide source + add the overlay in the same frame so they commit together —
    // no blank gap where the source briefly disappears.
    //
    // We intentionally do NOT hide OTHER heroes in the namespace. An earlier
    // version did ("auxiliaryHidden") for focus, but it made siblings far from
    // the flight path vanish (e.g. BasicImageHero: tapping one image blanked
    // every other under its caption during the flight, and again on the
    // back-flight as the list re-entered). The overlay is already on a
    // window-level layer; the screen-fade does the rest, and leaving siblings
    // visible matches Material container-transform.
    val sourceView = pending.source?.get()
    sourceView?.setHiddenForFlight(true)
    FlightEngine.run(snap, sourceView, dest, onAllDone = null)
    return true
  }

  private fun pollForLayout(dest: SharedHeroView, attemptsLeft: Int) {
    val attemptsUsed = MAX_LAYOUT_ATTEMPTS - attemptsLeft
    if (tryFire(dest, attemptsUsed)) return
    if (attemptsLeft <= 0) {
      val key = System.identityHashCode(dest)
      val pending = pendingFlights.remove(key)
      if (pending != null) {
        Log.d(TAG, "gave up waiting for dest layout dest=${id(dest)}")
        pending.source?.get()?.setHiddenForFlight(false)
        dest.setHiddenForFlight(false)
      }
      return
    }
    handler.post { pollForLayout(dest, attemptsLeft - 1) }
  }

  // MARK: - In-place match-pass path (unregister → register within 1 tick).

  private fun scheduleMatchPass() {
    if (matchScheduled) return
    matchScheduled = true
    handler.post { runMatchPass() }
  }

  private fun runMatchPass() {
    matchScheduled = false
    val keys = pendingMatchKeys.toList()
    pendingMatchKeys.clear()
    for (key in keys) {
      val dest = live[key]?.asReversed()?.firstNotNullOfOrNull { it.get() }
      val source = recentlyUnregistered.remove(key) ?: continue
      if (dest != null) {
        // Same-view churn guard (defense-in-depth, mirrors iOS): a reparent
        // can detach+reattach the SAME instance within a tick; flying it onto
        // itself paints a phantom snapshot over the dest (same-id churn ghost
        // bug). Skip it.
        if (source.sourceViewId == System.identityHashCode(dest)) {
          Log.d(TAG, "matchPass skip same-id churn key=$key dest=${id(dest)}")
          continue
        }
        val sourceSnap = resolveInPlaceSource(source.snapshot, key)
        Log.d(
          TAG,
          "matchPass fire key=$key dest=${id(dest)} " +
            "bitmap=${source.snapshot.bitmap?.let { "${it.width}x${it.height}" } ?: "null"} " +
            "blank=${isLikelyBlank(source.snapshot.bitmap)} usedFallback=${sourceSnap !== source.snapshot}",
        )
        dest.setHiddenForFlight(true)
        // `inPlace = true`: this fallback path also has no host transition to
        // mask the overlay handoff, so fire synchronously on layout-ready.
        queuePendingFlight(sourceSnap, null, dest, inPlace = true)
      }
    }
    recentlyUnregistered.clear()
  }

  /**
   * Resolve the SOURCE snapshot for an in-place flight. Prefers the freshly
   * captured [recent] snapshot; if its bitmap is blank (repeat-toggle failure)
   * falls back to the last known-good snapshot for [key] so we still fly a
   * visible bitmap. Keeps the outgoing view's geometry when usable, borrowing
   * only the bitmap from the fallback.
   */
  private fun resolveInPlaceSource(recent: HeroSnapshot, key: String): HeroSnapshot {
    if (recent.hasBitmap() && !isLikelyBlank(recent.bitmap)) return recent
    val fallback = lastKnownSnapshots[key]
    if (fallback != null && fallback.hasBitmap() && !isLikelyBlank(fallback.bitmap)) {
      val rect = if (recent.rect.width() > 0 && recent.rect.height() > 0) recent.rect else fallback.rect
      return HeroSnapshot(fallback.bitmap, rect, recent.cornerRadius, recent.backgroundColor)
    }
    return recent
  }

  private fun keyFor(view: SharedHeroView): String =
    "${view.config.heroNamespace}::${view.config.heroId}"

  private fun id(view: SharedHeroView): String = "@${Integer.toHexString(System.identityHashCode(view))}"

  private const val TAG = "SharedHeroRegistry"
  private const val MAX_LAYOUT_ATTEMPTS = 120

  /**
   * Max frames an IN-PLACE flight will wait for a non-blank bitmap (source or
   * destination) before firing best-effort. ~12 frames ≈ 200 ms at 60 Hz: long
   * enough for a memory-cached `<Image>` to composite after a cold-launch first
   * toggle, short enough that the brief hidden gap isn't perceptible.
   */
  private const val CONTENT_WAIT_ATTEMPTS = 12
}
