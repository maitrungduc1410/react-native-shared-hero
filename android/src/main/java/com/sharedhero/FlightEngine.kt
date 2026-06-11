package com.sharedhero

import android.animation.ArgbEvaluator
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.Rect
import android.os.SystemClock
import android.view.Choreographer
import android.view.View
import android.view.ViewOutlineProvider
import android.view.animation.AccelerateDecelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.view.animation.Interpolator
import android.view.animation.LinearInterpolator
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.dynamicanimation.animation.FloatValueHolder
import androidx.dynamicanimation.animation.SpringAnimation
import androidx.dynamicanimation.animation.SpringForce

/**
 * Snapshot/morph flight engine.
 *
 * Timing models:
 * - Time-based with easing (default).
 * - Spring-based via [SpringAnimation] when `springStiffness` and `springMass`
 *   are non-zero on the destination's config.
 *
 * Motion paths:
 * - `linear` (default): straight rectangular interpolation.
 * - `arc`: Material-y curved arc through the centre offset.
 */
object FlightEngine {

  private data class Geometry(
    val rect: Rect,
    val cornerRadius: Float,
    val backgroundColor: Int,
  )

  /**
   * Runs a flight from a previously-captured [source] snapshot to a still-
   * mounted [dest] view. Capturing the source up-front lets the engine survive
   * the host navigator detaching/moving the original source during the push/pop.
   *
   * [sourceView] is the live source view when available; we un-hide it after
   * the soft handoff so the previous screen's content is in place on back. Pass
   * `null` for the in-place match path where the source no longer exists.
   */
  fun run(
    source: HeroSnapshot,
    sourceView: SharedHeroView?,
    dest: SharedHeroView,
    onAllDone: (() -> Unit)? = null,
  ) {
    val cfg = dest.config
    val ctx = dest.context

    val endGeo = geometry(dest)
    android.util.Log.d(
      "SharedHeroFlight",
      "run start sourceRect=${source.rect} destRect=${endGeo.rect} mode=${cfg.mode} " +
        "sourceBitmap=${source.bitmap?.let { "${it.width}x${it.height}" } ?: "null"} " +
        "sourceBlank=${isLikelyBlankBitmap(source.bitmap)} " +
        "sourceRadiusPx=${source.cornerRadius} destRadiusPx=${endGeo.cornerRadius}",
    )
    if (endGeo.rect.width() <= 0 || endGeo.rect.height() <= 0) {
      android.util.Log.d("SharedHeroFlight", "run abort: dest not laid out")
      dest.setHiddenForFlight(false)
      sourceView?.setHiddenForFlight(false)
      onAllDone?.invoke()
      return
    }
    val initial = if (source.rect.width() <= 0) {
      Geometry(endGeo.rect, endGeo.cornerRadius, source.backgroundColor)
    } else {
      Geometry(source.rect, source.cornerRadius, source.backgroundColor)
    }

    // `zoom`/`auto` are reserved iOS 18+ system-zoom hints (v2); they alias to
    // `morph` everywhere else, including Android.
    val isMorph = cfg.mode == "morph" || cfg.mode == "zoom" || cfg.mode == "auto"

    var sourceBitmap = source.bitmap
    // Last-resort guard against flying a BLANK overlay (reads as "blank for a
    // frame then snap"). If the source bitmap is missing or fully transparent
    // — e.g. the cold-launch case where the small hero's rolling stash was
    // captured before its <Image> painted — recapture from the DEST instead:
    // it's laid out by now and a direct render ignores its hidden alpha, so it
    // yields the real (loaded) image. Still flown FROM the source rect, so the
    // user sees a real scale rather than nothing.
    if (sourceBitmap == null || isLikelyBlankBitmap(sourceBitmap)) {
      val fallback = dest.renderContentForFlightFallback()
      if (fallback?.bitmap != null && !isLikelyBlankBitmap(fallback.bitmap)) {
        sourceBitmap = fallback.bitmap
        android.util.Log.d(
          "SharedHeroFlight",
          "run recaptured dest bitmap (source was blank) size=${fallback.bitmap.width}x${fallback.bitmap.height}",
        )
      }
    }
    // NOTE: v1 flies only the source bitmap. Capturing the dest here would mean
    // temporarily un-hiding it (the registry hid it before queuing), risking a
    // one-frame flicker.
    if (sourceBitmap == null) {
      android.util.Log.d("SharedHeroFlight", "run abort: no source bitmap")
      dest.setHiddenForFlight(false)
      sourceView?.setHiddenForFlight(false)
      onAllDone?.invoke()
      return
    }
    val destBitmap: Bitmap? = null

    val container = FrameLayout(ctx).apply {
      // Corner rounding uses `clipToOutline` + a per-frame `ViewOutlineProvider`
      // round rect. The RenderNode applies this anti-aliased clip on the GPU
      // every frame, so the overlay stays rounded THROUGHOUT the flight,
      // interpolating source→dest radius and landing on the dest radius.
      //
      // An earlier `saveLayer` + PorterDuff `DST_IN` rounded mask (to better
      // match RN's `BackgroundStyleApplicator`) regressed badly: on a
      // hardware-accelerated canvas DST_IN doesn't composite across the child
      // ImageView's RenderNode boundary, so the clip was a no-op and the
      // overlay showed SQUARE corners the whole flight (rounded only returned at
      // handoff when the real dest, with its own RN clip, was revealed). Making
      // DST_IN work needs `LAYER_TYPE_SOFTWARE`, which re-rasterises the
      // (possibly full-screen) overlay every frame and risks jank. The GPU
      // outline clip is both reliable and cheap.
      clipToOutline = true
      outlineProvider = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
          outline.setRoundRect(0, 0, view.width, view.height, currentRadius(view))
        }
      }
      if (isMorph && initial.backgroundColor != Color.TRANSPARENT) {
        setBackgroundColor(initial.backgroundColor)
      }
      setRadius(this, initial.cornerRadius)
      // We intentionally do NOT promote this container to LAYER_TYPE_HARDWARE.
      // A hardware layer caches the display list in an offscreen RenderNode/FBO
      // so per-frame `translationX/Y` + `scaleX/Y` composite without
      // re-recording — but `clipToOutline` clipping is baked INTO that display
      // list, and per-frame `setRadius(...) + invalidateOutline()` updates the
      // outline WITHOUT invalidating the FBO, so the rounded shape would freeze
      // at the source radius and "snap" to the dest radius at handoff. Letting
      // the View re-record each frame keeps the source→dest corner morph smooth
      // (matching iOS's CABasicAnimation). The "no jump during main-thread
      // stalls" guarantee is preserved by the Choreographer animator's capped
      // per-frame delta (`MAX_FRAME_DT_MS`) — see [runFlight].
    }

    // NOTE: named `sourceImageView`/`destImageView`, not shadowing the
    // `sourceView: SharedHeroView?` param — the inner closures call
    // `setHiddenForFlight` on the SharedHeroView, not the ImageView.
    // ScaleType.MATRIX (not the default FIT_CENTER): `setupOverlayTransform`
    // drives the draw matrix per frame so the bitmap aspect-FILLS (center-crops)
    // the CURRENT interpolated rect every tick, like iOS's `.scaleAspectFill`.
    // FIT_CENTER would letterbox the square source inside the wide dest-sized
    // view and hold that one crop until the real view takes over at t=1 — the
    // aspect/crop snap reported on ArcPath.
    val sourceImageView = sourceBitmap?.let {
      ImageView(ctx).apply {
        setImageBitmap(it)
        scaleType = ImageView.ScaleType.MATRIX
      }
    }
    val destImageView = destBitmap?.let { ImageView(ctx).apply { setImageBitmap(it); alpha = 0f } }

    sourceImageView?.let { container.addView(it, FrameLayout.LayoutParams(MATCH, MATCH)) }
    destImageView?.let { container.addView(it, FrameLayout.LayoutParams(MATCH, MATCH)) }

    // Resolve the overlay from the DEST's own window, not just the host
    // Activity context. Same-window flights resolve to the Activity decor
    // (unchanged); for a core-<Modal> forward open the dest lives in the
    // Modal's separate Dialog window, so this hosts the flight in the Dialog
    // decor — ABOVE the modal content — instead of behind it.
    val overlay = OverlayHost.resolveOverlay(dest) ?: run {
      android.util.Log.d("SharedHeroFlight", "run abort: no overlay")
      dest.setHiddenForFlight(false)
      sourceView?.setHiddenForFlight(false)
      onAllDone?.invoke()
      return
    }
    measureAndLayout(container, initial.rect.left, initial.rect.top, initial.rect.right, initial.rect.bottom)
    overlay.add(container)
    android.util.Log.d("SharedHeroFlight", "container added rect=${initial.rect}")

    dest.setHiddenForFlight(true)
    dest.emitTransitionStart()

    // Soft handoff after the geometric flight finishes:
    //  1. Reveal the real dest content (still blank if its <Image> is loading)
    //     behind the snapshot.
    //  2. Fade the snapshot out — the loaded dest emerges through the fade, or
    //     a gentle fade instead of a hard pop.
    //  3. Un-hide the source so its real content is in place on back.
    val onComplete = {
      dest.setHiddenForFlight(false)
      container.animate()
        .alpha(0f)
        .setDuration(180L)
        .setInterpolator(DecelerateInterpolator())
        .withEndAction {
          overlay.remove(container)
          sourceView?.setHiddenForFlight(false)
          dest.emitTransitionEnd()
          onAllDone?.invoke()
        }
        .start()
    }

    if (cfg.usesSpring) {
      runSpringFlight(container, initial, endGeo, cfg, sourceImageView, destImageView, isMorph, onComplete)
    } else if (cfg.motionPath == "arc") {
      runArcFlight(container, initial, endGeo, cfg, sourceImageView, destImageView, isMorph, onComplete)
    } else {
      runLinearFlight(container, initial, endGeo, cfg, sourceImageView, destImageView, isMorph, onComplete)
    }
  }

  // MARK: - Time-based linear flight.

  private fun runLinearFlight(
    container: FrameLayout,
    initial: Geometry,
    end: Geometry,
    cfg: SharedHeroConfig,
    sourceView: View?,
    destView: View?,
    isMorph: Boolean,
    onComplete: () -> Unit,
  ) {
    val duration = maxOf(50, cfg.duration).toLong()
    val applyFrame = setupOverlayTransform(container, initial, end, cfg, sourceView, destView, isMorph)
    // Seed the visual to the source rect before the animator starts so the
    // first rendered frame already matches `initial`, even if the animator's
    // first update is one VSYNC late.
    applyFrame(initial.rect.exactCenterX(), initial.rect.exactCenterY(), initial.rect.width(), initial.rect.height(), 0f)

    val interp = easing(cfg.easing)
    runFlight(duration, interp) { t ->
      val cx = initial.rect.exactCenterX() + (end.rect.exactCenterX() - initial.rect.exactCenterX()) * t
      val cy = initial.rect.exactCenterY() + (end.rect.exactCenterY() - initial.rect.exactCenterY()) * t
      val w = (initial.rect.width() + (end.rect.width() - initial.rect.width()) * t).toInt()
      val h = (initial.rect.height() + (end.rect.height() - initial.rect.height()) * t).toInt()
      applyFrame(cx, cy, w, h, t)
    }.withEndAction(onComplete)
  }

  // MARK: - Choreographer-based animator with bounded per-frame delta.

  /**
   * Custom animator driving `onUpdate(t)` once per VSYNC, `t` = eased progress
   * through `durationMs`. Unlike [android.animation.ValueAnimator] it does NOT
   * catch up to wall-clock after a main-thread stall — the largest single
   * advance is capped to one nominal frame (`MAX_FRAME_DT_MS`).
   *
   * Why: during react-native-screens fragment fade transitions (`animation:
   * 'fade'`) the main thread spikes at the END of the animation — layer type
   * flips `LAYER_TYPE_HARDWARE → LAYER_TYPE_NONE` per screen via
   * `Screen.setTransitioning(false)` while Fabric commits the detail layout. A
   * 60–200 ms stall lets `ValueAnimator.animateBasedOnTime` jump `t` from ~0.4
   * to 1.0 on its next pulse — the hard "jump to the destination mid-flight"
   * reported on BasicImageHero / Tabs / CardMorph (all `animation: 'fade'`).
   * With the cap the same stall just lengthens the flight by ~stall_ms (a brief
   * pause) while the snapshot holds its last intermediate position.
   */
  private fun runFlight(
    durationMs: Long,
    interpolator: Interpolator,
    onUpdate: (Float) -> Unit,
  ): FlightHandle {
    val handle = FlightHandle()
    val choreographer = Choreographer.getInstance()
    var startTime = -1L
    var lastTickTime = -1L
    val callback = object : Choreographer.FrameCallback {
      override fun doFrame(frameTimeNanos: Long) {
        if (handle.cancelled) return
        val now = SystemClock.uptimeMillis()
        if (startTime < 0L) {
          startTime = now
          lastTickTime = now
        }
        val sinceLast = (now - lastTickTime).coerceAtLeast(0L)
        // If the gap since the last frame is huge (main-thread stall), pretend
        // it was at most one nominal frame so `t` advances smoothly instead of
        // skipping to wherever wall-clock says.
        val effectiveDt = sinceLast.coerceAtMost(MAX_FRAME_DT_MS)
        lastTickTime = now
        // Re-anchor `startTime` by the skipped time so future ticks continue
        // from the capped position, not the full elapsed-since-start.
        startTime += (sinceLast - effectiveDt)
        val rawT = ((now - startTime).toFloat() / durationMs).coerceIn(0f, 1f)
        val easedT = interpolator.getInterpolation(rawT).coerceIn(0f, 1f)
        onUpdate(easedT)
        if (rawT >= 1f) {
          handle.fireEnd()
        } else {
          choreographer.postFrameCallback(this)
        }
      }
    }
    choreographer.postFrameCallback(callback)
    return handle
  }

  /** Handle returned by [runFlight] so callers can register an end action. */
  private class FlightHandle {
    var cancelled = false
    private var endAction: (() -> Unit)? = null
    private var ended = false
    fun withEndAction(action: () -> Unit): FlightHandle {
      endAction = action
      if (ended) action()
      return this
    }
    fun fireEnd() {
      if (ended) return
      ended = true
      endAction?.invoke()
    }
  }

  // MARK: - Spring flight.

  private fun runSpringFlight(
    container: FrameLayout,
    initial: Geometry,
    end: Geometry,
    cfg: SharedHeroConfig,
    sourceView: View?,
    destView: View?,
    isMorph: Boolean,
    onComplete: () -> Unit,
  ) {
    val applyFrame = setupOverlayTransform(container, initial, end, cfg, sourceView, destView, isMorph)
    applyFrame(initial.rect.exactCenterX(), initial.rect.exactCenterY(), initial.rect.width(), initial.rect.height(), 0f)

    val holder = FloatValueHolder(0f)
    val spring = SpringAnimation(holder).apply {
      spring = SpringForce(1f).apply {
        stiffness = if (cfg.springStiffness > 0) cfg.springStiffness else 380f
        dampingRatio = computeDampingRatio(cfg)
      }
      setStartValue(0f)
      // The animated value is NORMALIZED progress in [0, 1], not pixels.
      // SpringAnimation's default `minimumVisibleChange`
      // (MIN_VISIBLE_CHANGE_PIXELS = 1.0) is calibrated for pixel-space values;
      // against a 0..1 range its equilibrium threshold (~0.75 in progress units)
      // is so coarse the spring is "settled" almost immediately and terminates
      // BEFORE any overshoot/bounce plays — the hero just slides over with no
      // perceptible spring (the reported symptom). The scale threshold (0.002)
      // lets it run its full underdamped course in both directions.
      minimumVisibleChange = DynamicAnimation.MIN_VISIBLE_CHANGE_SCALE
    }
    spring.addUpdateListener { _, value, _ ->
      val t = value.coerceIn(0f, 1.2f)
      val cx = initial.rect.exactCenterX() + (end.rect.exactCenterX() - initial.rect.exactCenterX()) * t
      val cy = initial.rect.exactCenterY() + (end.rect.exactCenterY() - initial.rect.exactCenterY()) * t
      val w = (initial.rect.width() + (end.rect.width() - initial.rect.width()) * t).toInt().coerceAtLeast(1)
      val h = (initial.rect.height() + (end.rect.height() - initial.rect.height()) * t).toInt().coerceAtLeast(1)
      applyFrame(cx, cy, w, h, t)
    }
    spring.addEndListener { _, _, _, _ ->
      applyFrame(end.rect.exactCenterX(), end.rect.exactCenterY(), end.rect.width(), end.rect.height(), 1f)
      onComplete()
    }
    spring.start()
  }

  /** Convert SpringConfig{damping, stiffness, mass} → DynamicAnimation damping ratio. */
  private fun computeDampingRatio(cfg: SharedHeroConfig): Float {
    if (cfg.springDamping <= 0 || cfg.springStiffness <= 0 || cfg.springMass <= 0) {
      return SpringForce.DAMPING_RATIO_LOW_BOUNCY
    }
    val critical = 2f * kotlin.math.sqrt(cfg.springStiffness * cfg.springMass)
    return (cfg.springDamping / critical).coerceIn(0.1f, 1.5f)
  }

  // MARK: - Arc-path flight (linear time + curved centre).

  private fun runArcFlight(
    container: FrameLayout,
    initial: Geometry,
    end: Geometry,
    cfg: SharedHeroConfig,
    sourceView: View?,
    destView: View?,
    isMorph: Boolean,
    onComplete: () -> Unit,
  ) {
    val duration = maxOf(50, cfg.duration).toLong()
    val applyFrame = setupOverlayTransform(container, initial, end, cfg, sourceView, destView, isMorph)
    applyFrame(initial.rect.exactCenterX(), initial.rect.exactCenterY(), initial.rect.width(), initial.rect.height(), 0f)

    val startCx = initial.rect.exactCenterX()
    val startCy = initial.rect.exactCenterY()
    val endCx = end.rect.exactCenterX()
    val endCy = end.rect.exactCenterY()
    val dx = endCx - startCx
    val dy = endCy - startCy
    val controlX = if (kotlin.math.abs(dx) > kotlin.math.abs(dy)) endCx else startCx
    val controlY = if (kotlin.math.abs(dx) > kotlin.math.abs(dy)) startCy else endCy

    val interp = arcPathInterpolator(cfg.easing)
    runFlight(duration, interp) { t ->
      val it = 1f - t
      val cx = it * it * startCx + 2f * it * t * controlX + t * t * endCx
      val cy = it * it * startCy + 2f * it * t * controlY + t * t * endCy
      val w = (initial.rect.width() + (end.rect.width() - initial.rect.width()) * t).toInt()
      val h = (initial.rect.height() + (end.rect.height() - initial.rect.height()) * t).toInt()
      applyFrame(cx, cy, w, h, t)
    }.withEndAction(onComplete)
  }

  // MARK: - Frame application & helpers.

  /**
   * Lay the overlay container out ONCE at the dest rect, then return a per-frame
   * closure that drives the visual via `translationX/Y` + `scaleX/Y`.
   *
   * Why not re-`measure`+`layout` every frame (as we used to)? Those traverse
   * the child hierarchy on the main thread and force the overlay (on the decor
   * via `ViewGroupOverlay`) to re-draw the whole host each frame. During a
   * native-stack push the main thread is already busy with react-native-screens
   * transition callbacks and Fabric commits, so that extra work pushed frame
   * time over 16 ms and the flight visibly stalled mid-animation (the "pause
   * then continue" users saw). Translation+scale are RenderNode properties:
   * they trigger no measure/layout and the compositor applies them on the
   * render thread, so a brief main-thread stall no longer skips flight frames.
   *
   * Laid out at the dest size, the outline-clipped radius is in END coords; we
   * divide the visible (interpolated) radius by the current scale so corners
   * look right at every scale, not just scale=1.
   */
  private fun setupOverlayTransform(
    container: FrameLayout,
    initial: Geometry,
    end: Geometry,
    cfg: SharedHeroConfig,
    sourceView: View?,
    destView: View?,
    isMorph: Boolean,
  ): (cx: Float, cy: Float, w: Int, h: Int, t: Float) -> Unit {
    measureAndLayout(container, end.rect.left, end.rect.top, end.rect.right, end.rect.bottom)
    val endW = end.rect.width().coerceAtLeast(1)
    val endH = end.rect.height().coerceAtLeast(1)
    val endCx = end.rect.exactCenterX()
    val endCy = end.rect.exactCenterY()
    container.pivotX = endW / 2f
    container.pivotY = endH / 2f
    val argb = ArgbEvaluator()

    // Intrinsic size of the flying bitmap, used to recompute its aspect-fill
    // crop every frame (see the matrix block below). Resolved from the source
    // ImageView's drawable so an empty/odd snapshot just skips the matrix and
    // falls back to whatever scale type is set.
    val srcImage = sourceView as? ImageView
    val bmpW = srcImage?.drawable?.intrinsicWidth ?: 0
    val bmpH = srcImage?.drawable?.intrinsicHeight ?: 0
    val aspectMatrix = Matrix()

    return { cx, cy, w, h, t ->
      val sx = w.toFloat() / endW
      val sy = h.toFloat() / endH
      container.scaleX = sx
      container.scaleY = sy
      container.translationX = cx - endCx
      container.translationY = cy - endCy

      // Continuous aspect-fill of the flying bitmap against the CURRENT
      // interpolated rect (w×h), mirroring iOS `.scaleAspectFill`. The container
      // is laid out at the DEST size and morphs aspect via a NON-UNIFORM scale
      // (sx != sy when aspects differ), which alone would squash a statically-
      // scaled child. Counteract by pre-scaling the image by (f / sx, f / sy),
      // `f` = the uniform on-screen cover scale for the current rect. Net: a
      // uniform center-crop every frame — undistorted square at t=0 (the list
      // thumb), the dest's wide crop at t=1 (the detail hero), morphing between
      // with no aspect/crop snap at handoff. Reusing one Matrix keeps this
      // allocation-free per frame.
      if (srcImage != null && bmpW > 0 && bmpH > 0 && w > 0 && h > 0 && sx > 0f && sy > 0f) {
        val f = maxOf(w.toFloat() / bmpW, h.toFloat() / bmpH)
        val msx = f / sx
        val msy = f / sy
        aspectMatrix.setScale(msx, msy)
        aspectMatrix.postTranslate(endW / 2f - bmpW / 2f * msx, endH / 2f - bmpH / 2f * msy)
        srcImage.imageMatrix = aspectMatrix
      }

      val visibleRadius = initial.cornerRadius + (end.cornerRadius - initial.cornerRadius) * t
      val avgScale = ((sx + sy) / 2f).coerceAtLeast(0.001f)
      // Laid out at END size, the outline is clipped in that space; dividing by
      // the current scale keeps the ON-SCREEN radius == `visibleRadius` every
      // frame. `invalidateOutline()` re-applies the clip without re-recording
      // the children.
      setRadius(container, visibleRadius / avgScale)
      container.invalidateOutline()

      if (isMorph) {
        val c = argb.evaluate(t.coerceIn(0f, 1f), initial.backgroundColor, end.backgroundColor) as Int
        container.setBackgroundColor(c)
      }
      applyFade(cfg.fadeMode, sourceView, destView, t.coerceIn(0f, 1f))
    }
  }

  /**
   * Measure + lay out an off-tree view ONCE at the dest rect. `ViewGroupOverlay`
   * children never join the host's measure/layout pass, so without this the
   * container would render at 0×0. After it, per-frame movement is driven by
   * `translationX/Y` + `scaleX/Y` on the RenderNode (see [setupOverlayTransform]).
   */
  private fun measureAndLayout(view: View, l: Int, t: Int, r: Int, b: Int) {
    val w = r - l
    val h = b - t
    view.measure(
      View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY),
      View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY),
    )
    view.layout(l, t, r, b)
  }

  private fun geometry(view: SharedHeroView): Geometry {
    // SETTLED rect for the dest. During a host transition (e.g. a native-stack
    // pop with parallax slide-in) the dest's ancestors carry transform
    // animations, so raw `windowRect()` reflects a transient position and the
    // flight lands wrong; `settledWindowRect()` is where the view ends up.
    val rect = view.settledWindowRect()
    // Corner radius / background color are mirrored onto `SharedHeroView` by
    // the manager's `@ReactProp` setters. We read them off the view (not
    // `outlineProvider` / `ColorDrawable`) because `ReactViewGroup` renders via
    // the `BackgroundStyleApplicator` composite-drawable system, which doesn't
    // expose them through the legacy outline / background paths.
    return Geometry(rect, view.cornerRadiusPx, view.backgroundColorInt)
  }

  private fun easing(name: String): Interpolator = when (name) {
    "linear" -> LinearInterpolator()
    "easeIn" -> AccelerateDecelerateInterpolator()
    "easeOut" -> DecelerateInterpolator()
    "easeInOut", "standard", "emphasized" -> AccelerateDecelerateInterpolator()
    else -> AccelerateDecelerateInterpolator()
  }

  private fun arcPathInterpolator(name: String): Interpolator = when (name) {
    // Material-3 emphasized arc curve approximation.
    "emphasized" -> PathInterpolator(0.05f, 0.7f, 0.1f, 1.0f)
    else -> AccelerateDecelerateInterpolator()
  }

  private fun applyFade(mode: String, source: View?, dest: View?, t: Float) {
    // With no dest snapshot to fade into, fading the source out would leave the
    // flight invisible by the end. Keep source at full alpha and let the
    // post-flight handoff do the smooth reveal.
    if (dest == null) return
    when (mode) {
      "in" -> dest.alpha = t
      "out" -> source?.alpha = 1f - t
      "through" -> {
        if (t < 0.5f) {
          source?.alpha = 1f - (t / 0.5f)
          dest.alpha = 0f
        } else {
          source?.alpha = 0f
          dest.alpha = (t - 0.5f) / 0.5f
        }
      }
      "cross" -> {
        source?.alpha = 1f - t
        dest.alpha = t
      }
      else -> {
        source?.alpha = 1f - t
        dest.alpha = t
      }
    }
  }

  private val RADIUS_TAG_KEY = "shared-hero:radius".hashCode()
  private fun setRadius(view: View, radius: Float) {
    view.setTag(RADIUS_TAG_KEY, radius)
  }
  private fun currentRadius(view: View): Float =
    (view.getTag(RADIUS_TAG_KEY) as? Float) ?: 0f

  private const val MATCH = FrameLayout.LayoutParams.MATCH_PARENT

  /**
   * Cap the per-frame progress to a single nominal 60 Hz frame (16 ms) plus
   * a small buffer. Empirically two-frame jumps (~33 ms) are invisible
   * while preventing the multi-hundred-ms catch-up jumps that
   * [android.animation.ValueAnimator] does after a main-thread stall.
   */
  private const val MAX_FRAME_DT_MS = 24L
}

private val SharedHeroConfig.usesSpring: Boolean
  get() = springStiffness > 0 && springMass > 0
