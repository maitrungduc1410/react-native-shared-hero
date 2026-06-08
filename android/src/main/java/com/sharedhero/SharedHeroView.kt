package com.sharedhero

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import com.facebook.react.bridge.ReactContext
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.events.Event
import com.facebook.react.views.view.ReactViewGroup

/**
 * Fabric host view for a shared-hero element.
 *
 * Extends [ReactViewGroup] (rather than plain `ViewGroup`) so that all
 * standard React Native view-style props — `borderRadius`, `overflow`,
 * `borderColor`, `borderWidth`, `backgroundColor`, etc. — flow into the
 * usual `BackgroundStyleApplicator` machinery and actually render. Without
 * this, a `<SharedHero style={{ borderRadius: 16, overflow: 'hidden' }}>`
 * would silently render square corners on Android while iOS works fine.
 *
 * Child layout is left to Fabric / Yoga via the normal `setFrame` /
 * `layout` mounting path that `ReactViewGroup` already supports; no
 * `onMeasure` / `onLayout` overrides needed.
 */
class SharedHeroView(context: Context?) : ReactViewGroup(context) {
  private companion object {
    /** Minimum gap between rolling [dispatchDraw] snapshot captures. */
    const val STASH_THROTTLE_MS = 120L
  }

  val config = SharedHeroConfig()

  /**
   * Border radius applied via the manager's `@ReactProp` setter, in
   * **physical pixels**. Mirrors what `BackgroundStyleApplicator` is
   * configured with and is read back by the flight engine so the overlay
   * can interpolate corner radius source→dest.
   */
  var cornerRadiusPx: Float = 0f
    internal set

  /**
   * Background color applied via the manager's `@ReactProp` setter. Read
   * back during morph-mode flights so the overlay can crossfade between
   * source and destination background tints.
   */
  var backgroundColorInt: Int = Color.TRANSPARENT
    internal set

  /** Becomes true once we've registered with the registry. */
  private var registered = false

  /**
   * The window-coordinate frame this view will occupy once any in-progress
   * ancestor animations finish. See `settledWindowRect()` for details.
   */
  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    // Tell the registry as soon as we have non-zero geometry so any
    // pending flight whose destination is THIS view can fire on the next
    // frame instead of polling until layout lands.
    if (w > 0 && h > 0) {
      HeroRegistry.notifyLayoutReady(this)
    }
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    // Re-attaching means any previously-stashed snapshot is stale.
    stashedSnapshot = null
    hasGoodStash = false
    detaching = false
    syncRegistration()
  }

  override fun onDetachedFromWindow() {
    // Mark detaching BEFORE unregister so the registry's
    // `captureOrCachedSnapshot()` returns the rolling stash captured in
    // [dispatchDraw] (while the view was still drawing real content) rather
    // than re-rendering the now-detached view.
    //
    // Why this matters: a `ViewGroup` detaches its CHILDREN FIRST, and React
    // Native's `<Image>` (Fresco) releases its drawable in its own
    // `onDetachedFromWindow`. So by the time we get here the child image is
    // already gone and a fresh `draw(Canvas)` would be BLANK. That blank
    // capture is what broke the in-place toggle: the source hero unmounts in
    // the SAME runloop tick the destination mounts, so the registry has no
    // live source to capture and falls back to our snapshot — a blank one made
    // the flight fly an invisible bitmap ("goes blank") with the real image
    // only appearing at the end ("snap").
    detaching = true
    if (registered) {
      HeroRegistry.unregister(this)
      registered = false
    }
    super.onDetachedFromWindow()
  }

  /**
   * Keep a rolling, always-fresh snapshot of the hero's visible content.
   *
   * `dispatchDraw` fires whenever the view actually (re)draws — notably when a
   * remote `<Image>` finishes loading and fades in — so capturing here means we
   * always hold a real bitmap from while the children were attached and
   * drawable. This is the fallback the registry uses for in-place toggles and
   * for any navigator that unmounts the source before the destination
   * re-attaches.
   *
   * - The `capturing` reentrancy guard is essential: [captureSnapshotRaw]
   *   itself calls `draw(Canvas)`, which re-enters `dispatchDraw`; without the
   *   guard that would recurse infinitely.
   * - Throttled so scrolling lists of heroes don't allocate a bitmap every
   *   frame; a slightly stale fallback position is harmless (navigation
   *   flights capture the source live while it's attached).
   * - Skipped while hidden for a flight (the content is alpha=0 → transparent).
   */
  override fun dispatchDraw(canvas: Canvas) {
    super.dispatchDraw(canvas)
    if (capturing || hiddenForFlight || detaching) return
    if (!registered || !config.enabled || config.heroId.isEmpty()) return
    if (width <= 0 || height <= 0) return
    val now = System.currentTimeMillis()
    // Throttle ONLY once we already hold a good (non-blank) stash — that's the
    // common scrolling-list case the throttle exists for. Until we have one,
    // attempt a capture on every draw: a remote `<Image>` paints into the view
    // a few frames AFTER first layout, and the draw triggered by that paint is
    // often the ONLY one before the view goes static, so a throttle here would
    // miss it. (Draws naturally stop once content is static, so this can't spin
    // — there's nothing to invalidate us.)
    //
    // This is the cold-launch fix: the old code stored the FIRST capture
    // (image not yet painted → fully transparent), advanced the throttle, and
    // never refreshed — so the very first in-place toggle flew a blank source.
    if (hasGoodStash && now - lastStashAt < STASH_THROTTLE_MS) return
    capturing = true
    try {
      captureSnapshotRaw()?.let {
        // Promote ONLY a non-blank render to the stash. A blank (fully
        // transparent) capture means the child `<Image>` hasn't painted yet;
        // keep the previous stash (or null) and retry on the next draw.
        if (it.bitmap != null && !isLikelyBlankBitmap(it.bitmap)) {
          stashedSnapshot = it
          lastStashAt = now
          hasGoodStash = true
        }
      }
    } finally {
      capturing = false
    }
  }

  /** Called by [SharedHeroViewManager] after each prop update. */
  fun onConfigChanged() {
    syncRegistration()
  }

  /**
   * Reset every piece of mutable hero state to defaults so this view
   * instance is safe to reuse in a fresh logical mount. Called from the
   * manager's [SharedHeroViewManager.prepareToRecycleView] and
   * [SharedHeroViewManager.onDropViewInstance] as a defensive belt-and-
   * braces measure.
   *
   * Today our manager doesn't actively opt into Fabric view recycling
   * (`setupViewRecycling` is not called) so `prepareToRecycleView` is
   * effectively never invoked by the mounting layer — but if recycling
   * is ever enabled, stale `hiddenForFlight` / `stashedSnapshot` / stale
   * `config` carried across reuses would make a freshly-mounted hero
   * start invisible, fly an old bitmap, or land at the wrong settled
   * geometry. Resetting here keeps the view-side state in sync with the
   * registry-side cleanup we already do in `HeroRegistry.register`.
   */
  fun resetHeroState() {
    if (registered) {
      HeroRegistry.unregister(this)
      registered = false
    }
    config.heroId = ""
    config.heroNamespace = "default"
    config.mode = "snapshot"
    config.duration = 320
    config.springDamping = 0f
    config.springStiffness = 0f
    config.springMass = 0f
    config.fadeMode = "cross"
    config.easing = "standard"
    config.motionPath = "linear"
    config.enabled = true
    config.returnFlightEnabled = true
    hiddenForFlight = false
    visibility = VISIBLE
    alpha = 1f
    stashedSnapshot = null
    hasGoodStash = false
    cornerRadiusPx = 0f
    backgroundColorInt = Color.TRANSPARENT
  }

  private fun syncRegistration() {
    val shouldRegister =
      isAttachedToWindow && config.enabled && config.heroId.isNotEmpty()
    if (shouldRegister && !registered) {
      HeroRegistry.register(this)
      registered = true
    } else if (!shouldRegister && registered) {
      HeroRegistry.unregister(this)
      registered = false
    } else if (shouldRegister && registered) {
      HeroRegistry.notifyConfigChanged(this)
    }
  }

  /**
   * Set when this view's content is being shown by a flight in the overlay.
   * We hide the in-place content so the user only sees the flying snapshot.
   *
   * Before transitioning to `hidden = true` we cache a clean snapshot — a
   * later `draw(Canvas)` on a view with `alpha = 0` produces a transparent
   * bitmap, so without this any flight that starts while we're still hidden
   * (e.g. user taps a new hero while the back-flight is still running)
   * would fly an invisible bitmap and the user would just see a fade with
   * no hero.
   */
  private var hiddenForFlight = false

  fun setHiddenForFlight(hidden: Boolean) {
    if (hiddenForFlight == hidden) return
    if (hidden) {
      captureSnapshotRaw()?.let {
        if (it.bitmap != null && !isLikelyBlankBitmap(it.bitmap)) {
          stashedSnapshot = it
          hasGoodStash = true
        }
      }
    }
    hiddenForFlight = hidden
    // Use both INVISIBLE and alpha so neither a parent fade animation nor a
    // React-side opacity prop can re-show the in-place content while the
    // overlay copy is flying.
    visibility = if (hidden) INVISIBLE else VISIBLE
    alpha = if (hidden) 0f else 1f
    if (!hidden) {
      // We've just been REVEALED after a flight. A view that was a flight's
      // DESTINATION (e.g. the large/small box in the InPlaceToggle example)
      // is `setHiddenForFlight(true)` from the instant it registers — before
      // its very first draw — and stays hidden for the whole flight, so
      // `dispatchDraw` never captures a rolling stash for it. Unless we force
      // one now, this view becomes the SOURCE of the NEXT toggle with a null
      // or blank stash, and the next flight flies an invisible bitmap →
      // "blank for a frame then snaps" on every toggle after the first.
      //
      // So eagerly refresh the rolling stash from a guaranteed-visible render.
      refreshStashSoon()
    }
    android.util.Log.d(
      "SharedHeroView",
      "setHiddenForFlight=$hidden view=${System.identityHashCode(this)} attached=$isAttachedToWindow stashed=${stashedSnapshot != null}",
    )
  }

  /**
   * Force the rolling stash to refresh from a real, on-window render so this
   * view is a valid flight SOURCE for the next in-place toggle.
   *
   * Why this is needed even though [dispatchDraw] already maintains a rolling
   * stash:
   * - The destination of an in-place flight is hidden for its whole formative
   *   life, so [dispatchDraw] never captured anything for it.
   * - Once revealed, static image content may produce only a single draw, and
   *   the [STASH_THROTTLE_MS] throttle can lock in a blank/incomplete first
   *   capture (e.g. captured a tick before the child `<Image>` re-composites)
   *   while skipping the good one. There's also no guarantee `dispatchDraw`
   *   re-fires at all for unchanging content after the reveal.
   *
   * We therefore reset the throttle and post a couple of forced captures: one
   * on the next frame (after the revealed content has drawn) and one after the
   * throttle window, so at least one lands on a fully-composited frame. We do
   * NOT null the existing stash here — keeping the last good one as a fallback
   * is strictly better than a null in case a re-toggle races the posts.
   */
  private fun refreshStashSoon() {
    lastStashAt = 0L
    invalidate()
    postCaptureStash()
    postDelayed({ postCaptureStash() }, STASH_THROTTLE_MS + 16L)
  }

  /**
   * Capture a fresh stash on a posted frame, bypassing the [dispatchDraw]
   * throttle. Stores only a non-blank bitmap from an attached, visible,
   * laid-out, non-hidden view so we never overwrite a good stash with a
   * transparent render.
   */
  private fun postCaptureStash() {
    post {
      if (capturing || hiddenForFlight || detaching) return@post
      if (!isAttachedToWindow || !registered) return@post
      if (!config.enabled || config.heroId.isEmpty()) return@post
      if (width <= 0 || height <= 0) return@post
      capturing = true
      try {
        captureSnapshotRaw()?.let {
          if (it.bitmap != null && !isLikelyBlankBitmap(it.bitmap)) {
            stashedSnapshot = it
            lastStashAt = System.currentTimeMillis()
            hasGoodStash = true
            android.util.Log.d(
              "SharedHeroView",
              "stash refresh view=${System.identityHashCode(this)} size=${it.bitmap.width}x${it.bitmap.height} rect=${it.rect}",
            )
          }
        }
      } finally {
        capturing = false
      }
    }
  }

  // MARK: - Geometry helpers used by FlightEngine.

  /**
   * Window-coordinate frame of this view AS CURRENTLY DISPLAYED, including any
   * translations/transforms from in-progress ancestor animations (e.g. a
   * native-stack push/pop parallax).
   */
  fun windowRect(): Rect {
    val out = IntArray(2)
    getLocationInWindow(out)
    return Rect(out[0], out[1], out[0] + width, out[1] + height)
  }

  /**
   * The window-space rect this view will occupy once any in-progress ancestor
   * animations finish. Walks the parent chain using each view's layout-time
   * `left/top` (which exclude `translationX/Y` and matrix transforms) minus
   * the parent's scroll offset, so a flight engine reading this value gets
   * the FINAL landing position even mid-transition.
   */
  fun settledWindowRect(): Rect {
    val w = width
    val h = height
    if (w <= 0 || h <= 0) return Rect()
    var x = 0
    var y = 0
    var v: android.view.View? = this
    while (v != null) {
      val parent = v.parent as? android.view.View
      if (parent != null) {
        x += v.left - parent.scrollX
        y += v.top - parent.scrollY
      } else {
        // Root view (e.g. DecorView) — no scrolling parent to compensate for.
        x += v.left
        y += v.top
      }
      v = parent
    }
    return Rect(x, y, x + w, y + h)
  }

  /**
   * Capture the view's current bitmap + geometry. If this view is currently
   * hidden by another in-flight transition (`setHiddenForFlight(true)`),
   * returns the pre-hide stash instead — `draw(Canvas)` on an alpha=0 view
   * renders transparent pixels, so without the stash a concurrent flight
   * starting from this view would fly an invisible bitmap.
   */
  fun captureSnapshot(): HeroSnapshot? {
    // While hidden (alpha=0) a live render is transparent, and once the view
    // has begun detaching its child <Image> has already released its drawable
    // so a live render is blank — in both cases prefer the pre-hide / pre-
    // detach stash captured while the content was still visible.
    if (hiddenForFlight || detaching) {
      stashedSnapshot?.let { return it }
    }
    return captureSnapshotRaw()
  }

  /**
   * Literal render of the view's current state. Used internally by
   * `setHiddenForFlight` (to stash before hiding) and by `captureSnapshot`
   * for the un-hidden path. Returns `null` if the view has no measured
   * dimensions.
   *
   * Renders the content WITHOUT the rounded `overflow: hidden` corner clip
   * that `ReactViewGroup.dispatchDraw` would otherwise bake into the bitmap.
   * Why: a source captured WITH its corners rounded carries that rounding as
   * a fixed proportion of its own (small) size. Scaled up to the destination
   * during a flight, the baked rounding becomes proportionally LARGER than the
   * destination's actual corner radius, so the flight overlay's corners look
   * rounder than the destination the whole way and visibly "pop" sharper at
   * handoff. By capturing SQUARE content and letting the flight overlay be the
   * sole source of corner rounding (interpolated source→dest, matching the
   * destination exactly at completion), there's no pop — mirroring how iOS's
   * `flightView.layer.cornerRadius` owns the rounding while the image subview
   * is an unrounded aspect-fill.
   */
  private fun captureSnapshotRaw(): HeroSnapshot? {
    if (width <= 0 || height <= 0) return null
    val bmp = try {
      val b = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
      drawContentUnclipped(Canvas(b))
      b
    } catch (_: Throwable) {
      null
    }
    return HeroSnapshot(
      bitmap = bmp,
      rect = windowRect(),
      cornerRadius = cornerRadiusPx,
      backgroundColor = backgroundColorInt,
    )
  }

  /**
   * Draw this hero's children onto [canvas] at their laid-out positions
   * WITHOUT going through `dispatchDraw` (which applies the rounded
   * `overflow: hidden` clip). The flight overlay supplies the corner rounding
   * instead — see [captureSnapshotRaw].
   *
   * Falls back to a normal `draw` when there are no children (nothing to draw
   * unclipped — e.g. a background-only hero), in which case there's no child
   * content whose corners could pop anyway.
   */
  private fun drawContentUnclipped(canvas: Canvas) {
    if (childCount == 0) {
      draw(canvas)
      return
    }
    for (i in 0 until childCount) {
      val child = getChildAt(i)
      if (child.visibility != VISIBLE) continue
      canvas.save()
      canvas.translate(child.left.toFloat(), child.top.toFloat())
      val m = child.matrix
      if (!m.isIdentity) canvas.concat(m)
      child.draw(canvas)
      canvas.restore()
    }
  }

  /**
   * Public escape hatch for [FlightEngine]: render the current content even
   * while this view is hidden for a flight. Used as a last resort when the
   * SOURCE snapshot came back blank — the still-laid-out destination's content
   * (a direct render ignores the view's hidden alpha) gives us a real bitmap
   * to fly instead of an invisible overlay.
   */
  fun renderContentForFlightFallback(): HeroSnapshot? = captureSnapshotRaw()

  /** Cached fallback set in `setHiddenForFlight` and the rolling `dispatchDraw`. */
  private var stashedSnapshot: HeroSnapshot? = null

  /**
   * Whether [stashedSnapshot] currently holds a verified NON-BLANK render.
   * Until it does, the rolling [dispatchDraw] capture skips its throttle so a
   * freshly-loaded `<Image>`'s first paint is captured promptly (the
   * cold-launch blank-source fix).
   */
  private var hasGoodStash = false

  /**
   * True between `onDetachedFromWindow` and the next `onAttachedToWindow`.
   * While set, [captureSnapshot] returns the stash because a live render of a
   * detaching view (whose child <Image> has released its Fresco drawable)
   * would be blank.
   */
  private var detaching = false

  /** Reentrancy guard for the rolling capture in [dispatchDraw]. */
  private var capturing = false

  /** Wall-clock time of the last rolling stash, for throttling. */
  private var lastStashAt = 0L

  /**
   * Returns a fresh snapshot if available, otherwise the most recent
   * stashed snapshot. Used by the registry's unregister path so the
   * back-flight can still fire when the source view has already left the
   * window.
   */
  fun captureOrCachedSnapshot(): HeroSnapshot? {
    val snap = captureSnapshot() ?: stashedSnapshot
    android.util.Log.d(
      "SharedHeroView",
      "captureOrCachedSnapshot view=${System.identityHashCode(this)} detaching=$detaching hidden=$hiddenForFlight " +
        "hadStash=${stashedSnapshot != null} bitmap=${snap?.bitmap?.let { "${it.width}x${it.height}" } ?: "null"} rect=${snap?.rect}",
    )
    return snap
  }

  // MARK: - Event emission.

  fun emitTransitionStart() {
    emit("topTransitionStart")
  }

  fun emitTransitionEnd() {
    emit("topTransitionEnd")
  }

  private fun emit(eventName: String) {
    val ctx = context as? ReactContext ?: return
    val surfaceId = UIManagerHelper.getSurfaceId(this)
    val dispatcher = UIManagerHelper.getEventDispatcher(ctx) ?: return
    dispatcher.dispatchEvent(
      SharedHeroEvent(surfaceId, id, eventName, config.heroId, config.heroNamespace),
    )
  }
}

/** Mirror of `SharedHeroConfig` from the JS spec, kept on the view. */
class SharedHeroConfig {
  var heroId: String = ""
  var heroNamespace: String = "default"
  var mode: String = "snapshot"
  var duration: Int = 320
  var springDamping: Float = 0f
  var springStiffness: Float = 0f
  var springMass: Float = 0f
  var fadeMode: String = "cross"
  var easing: String = "standard"
  var motionPath: String = "linear"
  var enabled: Boolean = true

  /**
   * When false, this hero performs a quiet teardown on unregister: it never
   * initiates a return/back-flight. Defaults to true (today's behaviour).
   */
  var returnFlightEnabled: Boolean = true
}

private class SharedHeroEvent(
  surfaceId: Int,
  viewTag: Int,
  private val name: String,
  private val heroId: String,
  private val heroNamespace: String,
) : Event<SharedHeroEvent>(surfaceId, viewTag) {
  override fun getEventName(): String = name
  override fun getEventData(): com.facebook.react.bridge.WritableMap? {
    val map = com.facebook.react.bridge.Arguments.createMap()
    map.putString("id", heroId)
    map.putString("ns", heroNamespace)
    return map
  }
}
