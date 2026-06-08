package com.sharedhero

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.lang.ref.WeakReference

/**
 * Process-wide registry of currently-mounted [SharedHeroView]s. Drives the
 * router-agnostic match logic.
 *
 * Two trigger paths exist:
 *
 * 1. **Twin appears while another is still live** — handles native-stack push
 *    and pop on react-native-screens, where both the previous and next
 *    screens' hero views are attached to the window during the navigator's
 *    slide animation. We capture the existing twin's snapshot the moment the
 *    new twin registers, so the source frame is recorded *before* the host
 *    navigator starts moving it, and schedule the flight on the next frame
 *    when the new twin has been laid out.
 *
 * 2. **Existing twin unregisters, then a new one mounts within one frame** —
 *    handles state-driven in-place transitions where one hero is unmounted
 *    and immediately replaced by a sibling with the same id.
 *
 * All access must be on the main thread.
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
   * Last known-good source snapshot per `(namespace, id)` key. Populated
   * whenever we queue a flight from a non-blank source bitmap, and used as a
   * last-resort fallback when an unregistering view can offer neither a live
   * render nor a usable stash (e.g. the InPlaceToggle destination whose stash
   * never refreshed). Mirrors iOS's `lastKnownSnapshots`. Without it, a
   * subsequent in-place toggle would either queue an invisible/blank flight
   * (blank → snap) or skip the overlay entirely.
   */
  private val lastKnownSnapshots = mutableMapOf<String, HeroSnapshot>()
  private val handler = Handler(Looper.getMainLooper())
  private var matchScheduled = false

  private fun HeroSnapshot.hasBitmap(): Boolean = bitmap != null

  /**
   * Source pending an in-place match. We keep the source view's identity
   * hash alongside the snapshot so the match logic can detect "the new dest
   * is the SAME view instance that just unregistered" — a host-navigator
   * reparent (detach + reattach within a tick) that must NOT fire a flight
   * from a view onto itself (the iOS "same-id churn" ghost-snapshot bug).
   */
  private data class PendingSource(val snapshot: HeroSnapshot, val sourceViewId: Int)

  /**
   * Flight queued waiting for the destination's first layout pass.
   *
   * [inPlace] marks a same-screen state toggle (unmount → remount of the same
   * id with no host-navigator transition). Such flights fire SYNCHRONOUSLY
   * from [notifyLayoutReady] — adding the overlay in the same frame the new
   * layout lands — because there is no screen transition to mask the
   * one-frame gap the normal deferred path would leave.
   */
  private data class PendingFlight(
    val snapshot: HeroSnapshot,
    val source: WeakReference<SharedHeroView>?,
    val inPlace: Boolean = false,
  )

  fun register(view: SharedHeroView) {
    // Fabric recycles RCT view instances. When a previously-recycled view
    // is GC'd, an identity hash can collide with a new view, OR if a
    // recycled view is reused, the same view re-registers later in a new
    // logical lifecycle. Either way, any state we keyed by its
    // `System.identityHashCode` belongs to the previous lifecycle and
    // must be cleared so this fresh registration starts from scratch.
    //
    // Symptom if we skip this: `alreadyFlighted` accumulates a stale entry
    // for a recycled view's address; on its next unregister we hit the
    // "already participated in a recent twin-flight, skip" branch and the
    // back-flight never fires.
    val viewId = System.identityHashCode(view)
    alreadyFlighted.remove(viewId)
    pendingFlights.remove(viewId)

    val key = keyFor(view)
    val bucket = live.getOrPut(key) { mutableListOf() }
    bucket.removeAll { it.get() == null || it.get() === view }

    // Prefer the most recently-registered twin that's still ATTACHED to a
    // window. Without this filter, rapid push/pop cycles can leave a stale
    // outgoing view in the bucket — `captureSnapshot()` would then bail (or
    // return an empty bitmap) and the flight would silently fail to render.
    val twin = bucket.asReversed().firstNotNullOfOrNull { ref ->
      val v = ref.get()
      if (v != null && v.isAttachedToWindow) v else null
    }
    bucket.add(WeakReference(view))

    if (twin != null && twin !== view) {
      runTwinFlight(source = twin, dest = view)
      return
    }

    // No live twin, but a twin with the SAME key unregistered earlier in this
    // runloop tick. On Android — where Fabric does NOT recycle our view — an
    // in-place toggle (e.g. the InPlaceToggle example: same `id`, different
    // React `key`, 120pt ↔ 320pt) unmounts the old hero and mounts a *brand
    // new* destination view, and Fabric processes the Remove mount item
    // BEFORE the Insert. So by the time this `register` runs the old twin has
    // already detached and the twin-on-register fast path above misses.
    //
    // If we just fell through to the async match-pass (as we used to), the
    // freshly-mounted destination would render once at its full destination
    // size before the next-tick match-pass hides it — the "hard snap" — and
    // the overlay would then appear a further tick later, leaving a visible
    // blank. There is no host-navigator transition here to mask either gap.
    //
    // Handle it synchronously instead: hide the destination NOW (we're inside
    // `onAttachedToWindow`, before the view's first draw, so it never renders
    // uncovered) and arm an in-place flight that fires the instant Fabric
    // applies the new layout in this same frame (see `notifyLayoutReady`).
    // This mirrors iOS's synchronous in-place `notifyLayoutReady` path.
    //
    // `sourceViewId != viewId` skips a host-navigator reparent that detached +
    // reattached the SAME instance within a tick — flying a view onto itself
    // renders a phantom snapshot over the destination (the iOS same-id churn
    // ghost bug).
    val recent = recentlyUnregistered[key]
    if (recent != null && recent.sourceViewId != viewId) {
      recentlyUnregistered.remove(key)
      pendingMatchKeys.remove(key)
      // The source snapshot was captured from the (now-detached) outgoing
      // view. If that bitmap is blank — the recurring repeat-toggle failure,
      // where the previous flight's destination became this source without
      // ever refreshing a real stash — fall back to the last known-good snap
      // for this key so we still fly a visible bitmap instead of nothing.
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
      // This view already played the source of a recent twin-flight; don't
      // re-arm the in-place match path with a now-stale snapshot.
      return
    }

    // Opt-out: a hero declared `returnFlightEnabled = false` performs a quiet
    // teardown — it never initiates a return/back-flight on unmount. Used by
    // the core `<Modal>` example whose dismiss is a plain slide-DOWN that
    // carries the hero off-screen with it; firing a back-flight here would
    // redundantly fly a snapshot back up to the list cell after the slide.
    if (!view.config.returnFlightEnabled) {
      Log.d(TAG, "unregister quiet teardown (returnFlightEnabled=false) source=${id(view)} key=$key")
      return
    }

    // `captureOrCachedSnapshot` falls back to the snapshot we stashed in
    // `onDetachedFromWindow` if the view is already off-window, so the
    // back-flight survives navigators that unmount the source before the
    // destination re-attaches.
    val snap = view.captureOrCachedSnapshot()
    Log.d(
      TAG,
      "unregister source=${id(view)} key=$key " +
        "bitmap=${snap?.bitmap?.let { "${it.width}x${it.height}" } ?: "null"} " +
        "blank=${isLikelyBlank(snap?.bitmap)} rect=${snap?.rect}",
    )

    // Fast path: a sibling twin is still attached. Fire back-flight now
    // without waiting for the match-pass tick. Covers navigators that keep
    // both screens attached (the destination won't re-register and the
    // twin-on-register path can't trigger).
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
    // Hide DEST now (it's about to be laid out and we don't want it to flash
    // visible). Source is hidden later in `tryFire` so its disappearance and
    // the flight overlay's appearance commit in the same frame — no visible
    // blank.
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
    // Remember the last known-good (non-blank) source snapshot for this key so
    // a future toggle whose source can't produce a usable bitmap can fall back
    // to it instead of flying an invisible overlay.
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
      // In-place toggle: no host-navigator transition exists to mask a
      // one-frame gap, so fire SYNCHRONOUSLY in this layout pass. We are
      // inside `onSizeChanged` (i.e. inside the view's `layout` pass), where
      // the view's and its ancestors' `left/top/right/bottom` are already
      // assigned, so `settledWindowRect()` (which the flight engine uses for
      // the destination, NOT `getLocationInWindow`) is stable. Adding the
      // overlay in this same frame means the destination is hidden, the
      // overlay covers the source position, and the morph all commit together
      // — no snap to the destination size, no blank gap.
      tryFire(view, attemptsUsed = 0)
      return
    }
    // Navigation flights: defer to the next frame so `getLocationInWindow` and
    // any in-progress host-navigator transform have a tick to settle.
    handler.post { tryFire(view, attemptsUsed = 0) }
  }

  private fun tryFire(dest: SharedHeroView, attemptsUsed: Int): Boolean {
    val key = System.identityHashCode(dest)
    val pending = pendingFlights[key] ?: return true
    if (!dest.isAttachedToWindow || dest.width <= 0 || dest.height <= 0) {
      return false
    }

    // Resolve the best available NON-BLANK source bitmap, in priority order:
    //   1. the captured source snapshot (the common case),
    //   2. the DESTINATION's freshly-rendered content — for an in-place toggle
    //      this is the SAME image, and `renderContentForFlightFallback()` draws
    //      it directly so it ignores the dest's hidden alpha,
    //   3. the per-key last-known-good snapshot.
    // Any non-blank capture is promoted into `lastKnownSnapshots` so future
    // toggles always have a fallback.
    //
    // Why this matters: on a COLD-LAUNCH FIRST in-place toggle the captured
    // source is blank (the remote <Image> composites a few frames after mount)
    // AND there's no prior known-good snapshot, so without this the flight flew
    // an invisible overlay — "blank for a frame, then snap to the destination
    // image". Subsequent toggles worked only because by then the image had
    // painted and `lastKnownSnapshots` was populated.
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

    // Cold-launch first toggle: neither the source, the destination, nor a
    // prior snapshot has a painted bitmap yet. Rather than fly a blank overlay,
    // wait a bounded number of frames for the <Image> to paint — the
    // destination stays hidden meanwhile (the source already unmounted), so
    // there is no flash of the destination size. The parallel `pollForLayout`
    // loop re-invokes us each frame; once the budget is spent we fire
    // best-effort so we never hang or leave the destination hidden.
    if (!haveContent && pending.inPlace && attemptsUsed < CONTENT_WAIT_ATTEMPTS) {
      return false
    }

    pendingFlights.remove(key)
    Log.d(
      TAG,
      "flight fire dest=${id(dest)} settledRect=${dest.settledWindowRect()} " +
        "attemptsUsed=$attemptsUsed haveContent=$haveContent",
    )
    // Hide source + add overlay snapshot in the same frame so they commit
    // together; no blank gap where the source view briefly disappears.
    //
    // We intentionally do NOT hide OTHER heros in the same namespace. An
    // earlier version did ("auxiliaryHidden") to keep visual focus on the
    // single flying snapshot, but that produced an obvious bug on screens
    // with multiple heros far away from the flight path (e.g.
    // BasicImageHero — a vertical list where tapping one image made every
    // OTHER image disappear under its caption while the flight ran, and
    // the same gap re-appeared during the back-flight as the list re-
    // entered the window). The flight overlay is already on a window-level
    // layer above everything; the natural screen-fade does the rest, and
    // leaving siblings visible matches Material container-transform
    // behaviour.
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
        // Same-view churn guard (defense-in-depth, mirrors iOS): a host-
        // navigator reparent can detach + reattach the SAME view instance
        // within a tick. Firing a flight from that view onto itself animates
        // a phantom snapshot over the destination (the iOS "same-id churn"
        // ghost bug). Skip it.
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
   * captured [recent] snapshot, but if its bitmap is blank (the repeat-toggle
   * failure mode) falls back to the last known-good snapshot for [key] so the
   * flight still flies a visible bitmap. The outgoing view's geometry is kept
   * when usable; only the bitmap content is borrowed from the fallback.
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
