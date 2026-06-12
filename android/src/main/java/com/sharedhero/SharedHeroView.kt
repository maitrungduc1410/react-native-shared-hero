package com.sharedhero

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import com.facebook.react.bridge.ReactContext
import com.facebook.react.uimanager.UIManagerHelper
import com.facebook.react.uimanager.common.UIManagerType
import com.facebook.react.uimanager.events.Event
import com.facebook.react.views.view.ReactViewGroup

/**
 * Fabric host view for a shared-hero element.
 *
 * Extends [ReactViewGroup] (not plain `ViewGroup`) so standard RN view-style
 * props — `borderRadius`, `overflow`, `borderColor`, `borderWidth`,
 * `backgroundColor`, etc. — flow into `BackgroundStyleApplicator` and actually
 * render; otherwise `<SharedHero style={{ borderRadius: 16, overflow:
 * 'hidden' }}>` silently renders square corners on Android while iOS works.
 *
 * Child layout is left to Fabric/Yoga via `ReactViewGroup`'s normal
 * `setFrame`/`layout` path; no `onMeasure`/`onLayout` overrides needed.
 */
class SharedHeroView(context: Context?) : ReactViewGroup(context) {
  private companion object {
    /** Minimum gap between rolling [dispatchDraw] snapshot captures. */
    const val STASH_THROTTLE_MS = 120L
  }

  val config = SharedHeroConfig()

  /**
   * Border radius (in **physical pixels**) mirrored from the manager's
   * `@ReactProp` setter. Read back by the flight engine to interpolate the
   * overlay's corner radius source→dest.
   */
  var cornerRadiusPx: Float = 0f
    internal set

  /**
   * Background color mirrored from the manager's `@ReactProp` setter. Read back
   * during morph-mode flights to crossfade the overlay between source and dest
   * background tints.
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
    // Notify the registry the moment we have non-zero geometry so a pending
    // flight whose destination is THIS view fires next frame instead of polling
    // until layout lands.
    if (w > 0 && h > 0) {
      HeroRegistry.notifyLayoutReady(this)
    }
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    // Re-attaching: any previously-stashed snapshot is stale.
    stashedSnapshot = null
    hasGoodStash = false
    detaching = false
    syncRegistration()
  }

  override fun onDetachedFromWindow() {
    // Mark detaching BEFORE unregister so the registry's
    // `captureOrCachedSnapshot()` returns the [dispatchDraw] rolling stash
    // (captured while the view still drew real content) instead of re-rendering
    // the now-detached view.
    //
    // Why: a `ViewGroup` detaches its CHILDREN first, and RN's `<Image>`
    // (Fresco) releases its drawable in its own `onDetachedFromWindow`, so by
    // now the child image is gone and a fresh `draw(Canvas)` is BLANK. That
    // blank capture broke the in-place toggle: the source unmounts in the SAME
    // tick the dest mounts, so the registry has no live source and falls back
    // to our snapshot — a blank one flew an invisible bitmap ("goes blank")
    // with the real image only appearing at the end ("snap").
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
   * `dispatchDraw` fires whenever the view (re)draws — notably when a remote
   * `<Image>` finishes loading and fades in — so we always hold a real bitmap
   * from while the children were attached and drawable. This is the fallback
   * the registry uses for in-place toggles and for any navigator that unmounts
   * the source before the dest re-attaches.
   *
   * - The `capturing` reentrancy guard is essential: [captureSnapshotRaw] calls
   *   `draw(Canvas)`, which re-enters `dispatchDraw` — infinite recursion
   *   without it.
   * - Throttled so scrolling lists don't allocate a bitmap every frame; a
   *   slightly stale fallback is harmless (navigation flights capture the
   *   source live while attached).
   * - Skipped while hidden for a flight (content is alpha=0 → transparent).
   */
  override fun dispatchDraw(canvas: Canvas) {
    super.dispatchDraw(canvas)
    if (capturing || hiddenForFlight || detaching) return
    if (!registered || !config.enabled || config.heroId.isEmpty()) return
    if (width <= 0 || height <= 0) return
    val now = System.currentTimeMillis()
    // Throttle ONLY once we hold a good (non-blank) stash — the common
    // scrolling-list case the throttle exists for. Until then, capture on every
    // draw: a remote `<Image>` paints a few frames AFTER first layout, and that
    // paint's draw is often the ONLY one before the view goes static, so a
    // throttle here would miss it. (Draws stop once content is static, so this
    // can't spin.)
    //
    // The cold-launch fix: the old code stored the FIRST capture (image not yet
    // painted → transparent), advanced the throttle, and never refreshed — so
    // the very first in-place toggle flew a blank source.
    if (hasGoodStash && now - lastStashAt < STASH_THROTTLE_MS) return
    capturing = true
    try {
      captureSnapshotRaw()?.let {
        // Promote ONLY a non-blank render. A blank (transparent) capture means
        // the child `<Image>` hasn't painted yet; keep the previous stash (or
        // null) and retry next draw.
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
   * Reset all mutable hero state to defaults so this instance is safe to reuse
   * in a fresh logical mount. Called defensively from the manager's
   * [SharedHeroViewManager.prepareToRecycleView] and
   * [SharedHeroViewManager.onDropViewInstance].
   *
   * We don't opt into Fabric view recycling today (`setupViewRecycling` is
   * never called), so `prepareToRecycleView` is effectively never invoked — but
   * if recycling is ever enabled, stale `hiddenForFlight` / `stashedSnapshot` /
   * `config` carried across reuses would make a fresh hero start invisible, fly
   * an old bitmap, or land at the wrong settled geometry. Mirrors the
   * registry-side cleanup in `HeroRegistry.register`.
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
   * Set when this view's content is being shown by a flight in the overlay; we
   * hide the in-place content so only the flying snapshot is visible.
   *
   * Before `hidden = true` we cache a clean snapshot — a later `draw(Canvas)`
   * on an `alpha = 0` view is transparent, so without this a flight starting
   * while we're still hidden (e.g. tapping a new hero mid back-flight) would
   * fly an invisible bitmap and the user would see a fade with no hero.
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
    // Use both INVISIBLE and alpha so neither a parent fade nor a React-side
    // opacity prop can re-show the in-place content while the overlay flies.
    visibility = if (hidden) INVISIBLE else VISIBLE
    alpha = if (hidden) 0f else 1f
    if (!hidden) {
      // Just REVEALED after a flight. A flight DESTINATION (e.g. the large/small
      // box in InPlaceToggle) is hidden from the instant it registers — before
      // its first draw — and stays hidden the whole flight, so `dispatchDraw`
      // never captured a rolling stash for it. Without forcing one now, this
      // view becomes the SOURCE of the NEXT toggle with a null/blank stash and
      // the next flight flies an invisible bitmap → "blank for a frame then
      // snaps" on every toggle after the first. So eagerly refresh from a
      // guaranteed-visible render.
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
   * Needed even though [dispatchDraw] maintains a rolling stash, because:
   * - An in-place flight's destination is hidden for its whole formative life,
   *   so [dispatchDraw] never captured anything for it.
   * - Once revealed, static image content may produce only a single draw, and
   *   the [STASH_THROTTLE_MS] throttle can lock in a blank/incomplete capture
   *   (taken a tick before the child `<Image>` re-composites) while skipping the
   *   good one — and `dispatchDraw` may not re-fire at all for static content.
   *
   * So reset the throttle and post two forced captures: one next frame (after
   * the revealed content draws) and one past the throttle window, so at least
   * one lands on a fully-composited frame. We do NOT null the existing stash —
   * keeping the last good one beats a null if a re-toggle races the posts.
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
   * laid-out, non-hidden view so we never overwrite a good stash with blank.
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
   * Literal render of the view's current state. Used by `setHiddenForFlight`
   * (to stash before hiding) and `captureSnapshot`'s un-hidden path. `null` if
   * the view has no measured dimensions.
   *
   * Renders WITHOUT the rounded `overflow: hidden` clip that
   * `ReactViewGroup.dispatchDraw` would bake into the bitmap. Why: a source
   * captured WITH rounded corners carries that rounding as a fixed proportion
   * of its own (small) size; scaled up to the dest it becomes proportionally
   * LARGER than the dest's radius, so the overlay looks rounder the whole way
   * and "pops" sharper at handoff. Capturing SQUARE content and letting the
   * overlay own all rounding (interpolated source→dest, exact at completion)
   * removes the pop — mirroring iOS where `flightView.layer.cornerRadius` owns
   * rounding while the image subview is an unrounded aspect-fill.
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
   * Draw this hero's children onto [canvas] at their laid-out positions WITHOUT
   * `dispatchDraw`'s rounded `overflow: hidden` clip; the overlay supplies the
   * rounding instead — see [captureSnapshotRaw].
   *
   * Falls back to a normal `draw` when there are no children (e.g. a
   * background-only hero), where no child corners could pop anyway.
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
    // Use the two-arg `getEventDispatcher` (passing FABRIC, as this is a Fabric
    // view): it exists on RN < 0.85 AND >= 0.85. The single-arg overload was
    // only added in 0.85, so calling it breaks compilation on 0.84 ("No value
    // passed for parameter 'uiManagerType'"). On >= 0.85 the two-arg form is
    // deprecated (it just delegates to the single-arg one) — hence the suppress.
    @Suppress("DEPRECATION")
    val dispatcher = UIManagerHelper.getEventDispatcher(ctx, UIManagerType.FABRIC) ?: return
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
