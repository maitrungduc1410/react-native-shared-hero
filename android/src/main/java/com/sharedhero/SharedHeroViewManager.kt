package com.sharedhero

import com.facebook.react.bridge.DynamicFromObject
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.BackgroundStyleApplicator
import com.facebook.react.uimanager.LengthPercentage
import com.facebook.react.uimanager.LengthPercentageType
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.ViewProps
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.uimanager.style.BorderRadiusProp
import com.facebook.react.uimanager.style.BorderStyle
import com.facebook.react.uimanager.style.LogicalEdge
import com.facebook.react.views.view.ReactClippingViewManager
import com.facebook.react.viewmanagers.SharedHeroViewManagerDelegate
import com.facebook.react.viewmanagers.SharedHeroViewManagerInterface

/**
 * Extends [ReactClippingViewManager] (not plain `ViewGroupManager`) to inherit
 * `removeClippedSubviews` and the standard layout/transform/opacity pipeline.
 *
 * ## Why we wrap the codegen delegate
 *
 * `<SharedHero>` is a Fabric component whose props dispatch through the codegen
 * [SharedHeroViewManagerDelegate], which handles our component-specific props
 * (`heroId`, `mode`, `duration`, …) and falls through to
 * [com.facebook.react.uimanager.BaseViewManagerDelegate] for the rest.
 *
 * But `BaseViewManagerDelegate.setProperty(BORDER_RADIUS, …)` calls the
 * DEPRECATED `setBorderRadius(view, Float)` overload on
 * [com.facebook.react.uimanager.BaseViewManager] — a
 * `logUnsupportedPropertyWarning(...)` no-op. The working
 * `setBorderRadius(view, Int, Dynamic)` overload (which routes through
 * [BackgroundStyleApplicator]) lives only on
 * [com.facebook.react.views.view.ReactViewManager], which we can't extend (it's
 * hard-fixed to `ReactViewGroup` as its generic parameter).
 *
 * So `<SharedHero style={{ borderRadius, overflow, borderWidth, borderColor,
 * ... }}>` was silently dropping those props on Android while iOS worked.
 * Per-prop `@ReactProp` methods don't help either — codegen-fronted Fabric
 * components bypass the `@ReactProp` reflection path entirely.
 *
 * Fix: wrap the codegen delegate with [HeroStylePropDelegate], which intercepts
 * the standard view-style prop names and routes them through
 * `BackgroundStyleApplicator` before deferring to the codegen+base chain.
 */
@ReactModule(name = SharedHeroViewManager.NAME)
class SharedHeroViewManager :
  ReactClippingViewManager<SharedHeroView>(),
  SharedHeroViewManagerInterface<SharedHeroView> {

  private val mCodegenDelegate: ViewManagerDelegate<SharedHeroView> =
    SharedHeroViewManagerDelegate(this)

  private val mDelegate: ViewManagerDelegate<SharedHeroView> =
    HeroStylePropDelegate(mCodegenDelegate)

  override fun getDelegate(): ViewManagerDelegate<SharedHeroView> = mDelegate

  override fun getName(): String = NAME

  public override fun createViewInstance(context: ThemedReactContext): SharedHeroView =
    SharedHeroView(context)

  override fun onAfterUpdateTransaction(view: SharedHeroView) {
    super.onAfterUpdateTransaction(view)
    view.onConfigChanged()
  }

  /**
   * Defensive cleanup for Fabric view recycling.
   *
   * `super.prepareToRecycleView` returns the view if recyclable, else `null`.
   * We reset all hero-specific state on the survivor so its next mount starts
   * fresh — stale `hiddenForFlight` / `stashedSnapshot` / `config` would
   * otherwise leak through and make the next `SharedHero` at this instance
   * render invisible or fly the wrong bitmap.
   *
   * NOTE: only fires if recycling is enabled (someone calls
   * `setupViewRecycling()`, or Fabric flips its default). We don't opt in today,
   * but the defensive cost is one nil-guarded call.
   */
  override fun prepareToRecycleView(
    reactContext: ThemedReactContext,
    view: SharedHeroView,
  ): SharedHeroView? {
    val prepared = super.prepareToRecycleView(reactContext, view)
    prepared?.resetHeroState()
    return prepared
  }

  /**
   * Called by Fabric when a view is permanently dropped (not recycled).
   * `onDetachedFromWindow` should already have unregistered us, but if the
   * mounting layer drops a view that never detached (e.g. surface teardown),
   * this avoids leaving a stale weak ref in [HeroRegistry] or a half-armed
   * flight.
   */
  override fun onDropViewInstance(view: SharedHeroView) {
    super.onDropViewInstance(view)
    view.resetHeroState()
  }

  override fun getExportedCustomDirectEventTypeConstants(): MutableMap<String, Any> {
    val base = super.getExportedCustomDirectEventTypeConstants() ?: mutableMapOf()
    base["topTransitionStart"] = mapOf("registrationName" to "onTransitionStart")
    base["topTransitionEnd"] = mapOf("registrationName" to "onTransitionEnd")
    return base
  }

  // `BaseViewManagerDelegate` already routes `BACKGROUND_COLOR` to
  // `setBackgroundColor(view, Int)` via `BackgroundStyleApplicator`, so unlike
  // `borderRadius` / `overflow` we just OVERRIDE this (no delegate intercept) to
  // mirror the value onto the view for the morph-mode flight engine.
  override fun setBackgroundColor(view: SharedHeroView, backgroundColor: Int) {
    super.setBackgroundColor(view, backgroundColor)
    view.backgroundColorInt = backgroundColor
  }

  // MARK: - Codegen-driven prop setters.

  @ReactProp(name = "heroId")
  override fun setHeroId(view: SharedHeroView?, value: String?) {
    view?.config?.heroId = value ?: ""
  }

  @ReactProp(name = "heroNamespace")
  override fun setHeroNamespace(view: SharedHeroView?, value: String?) {
    view?.config?.heroNamespace = if (value.isNullOrEmpty()) "default" else value
  }

  @ReactProp(name = "mode")
  override fun setMode(view: SharedHeroView?, value: String?) {
    view?.config?.mode = if (value.isNullOrEmpty()) "snapshot" else value
  }

  @ReactProp(name = "duration")
  override fun setDuration(view: SharedHeroView?, value: Int) {
    view?.config?.duration = if (value > 0) value else 320
  }

  @ReactProp(name = "springDamping")
  override fun setSpringDamping(view: SharedHeroView?, value: Float) {
    view?.config?.springDamping = value
  }

  @ReactProp(name = "springStiffness")
  override fun setSpringStiffness(view: SharedHeroView?, value: Float) {
    view?.config?.springStiffness = value
  }

  @ReactProp(name = "springMass")
  override fun setSpringMass(view: SharedHeroView?, value: Float) {
    view?.config?.springMass = value
  }

  @ReactProp(name = "fadeMode")
  override fun setFadeMode(view: SharedHeroView?, value: String?) {
    view?.config?.fadeMode = if (value.isNullOrEmpty()) "cross" else value
  }

  @ReactProp(name = "easing")
  override fun setEasing(view: SharedHeroView?, value: String?) {
    view?.config?.easing = if (value.isNullOrEmpty()) "standard" else value
  }

  @ReactProp(name = "motionPath")
  override fun setMotionPath(view: SharedHeroView?, value: String?) {
    view?.config?.motionPath = if (value.isNullOrEmpty()) "linear" else value
  }

  @ReactProp(name = "enabled")
  override fun setEnabled(view: SharedHeroView?, value: Boolean) {
    view?.config?.enabled = value
  }

  @ReactProp(name = "returnFlightEnabled")
  override fun setReturnFlightEnabled(view: SharedHeroView?, value: Boolean) {
    view?.config?.returnFlightEnabled = value
  }

  companion object {
    const val NAME = "SharedHeroView"
  }
}

/**
 * Style-prop interceptor that fixes Fabric prop dispatch for [SharedHeroView].
 *
 * The standard RN view-style props (`borderRadius`, `overflow`, `borderWidth`,
 * `borderColor`, `borderStyle`) must flow through [BackgroundStyleApplicator]
 * to render. The default codegen-fronted path (codegen delegate →
 * [BaseViewManagerDelegate]) either routes them to deprecated no-op setters
 * (`BORDER_RADIUS` hits only the Float "unsupported property" overload) or
 * drops them entirely (`OVERFLOW`, `BORDER_STYLE`, per-side `BORDER_WIDTH` /
 * `BORDER_COLOR` aren't in its switch at all).
 *
 * We intercept those names and apply them as
 * [com.facebook.react.views.view.ReactViewManager] does for stock
 * `ReactViewGroup`, then defer to the codegen delegate for our
 * component-specific props + the rest (`backgroundColor`, `transform`,
 * `opacity`, …).
 *
 * NOTE: lives next to [SharedHeroViewManager] (not its own module) since it has
 * no public surface and is meaningless in isolation — it knows the exact props
 * the codegen delegate fails to dispatch for `SharedHeroView`.
 */
private class HeroStylePropDelegate(
  private val inner: ViewManagerDelegate<SharedHeroView>,
) : ViewManagerDelegate<SharedHeroView> {

  override fun setProperty(view: SharedHeroView, propName: String, value: Any?) {
    when (propName) {
      // Border radius — uniform + all 12 per-corner variants.
      ViewProps.BORDER_RADIUS,
      ViewProps.BORDER_TOP_LEFT_RADIUS,
      ViewProps.BORDER_TOP_RIGHT_RADIUS,
      ViewProps.BORDER_BOTTOM_RIGHT_RADIUS,
      ViewProps.BORDER_BOTTOM_LEFT_RADIUS,
      ViewProps.BORDER_TOP_START_RADIUS,
      ViewProps.BORDER_TOP_END_RADIUS,
      ViewProps.BORDER_BOTTOM_START_RADIUS,
      ViewProps.BORDER_BOTTOM_END_RADIUS,
      ViewProps.BORDER_END_END_RADIUS,
      ViewProps.BORDER_END_START_RADIUS,
      ViewProps.BORDER_START_END_RADIUS,
      ViewProps.BORDER_START_START_RADIUS,
      -> applyBorderRadius(view, propName, value)

      ViewProps.OVERFLOW -> view.overflow = value as String?

      "borderStyle" -> {
        val parsed = (value as? String)?.let { BorderStyle.fromString(it) }
        BackgroundStyleApplicator.setBorderStyle(view, parsed)
      }

      // Border width — uniform + 6 per-side variants.
      ViewProps.BORDER_WIDTH,
      ViewProps.BORDER_LEFT_WIDTH,
      ViewProps.BORDER_RIGHT_WIDTH,
      ViewProps.BORDER_TOP_WIDTH,
      ViewProps.BORDER_BOTTOM_WIDTH,
      ViewProps.BORDER_START_WIDTH,
      ViewProps.BORDER_END_WIDTH,
      -> applyBorderWidth(view, propName, value)

      // Border color — uniform + 9 per-side variants (physical + logical).
      ViewProps.BORDER_COLOR,
      ViewProps.BORDER_LEFT_COLOR,
      ViewProps.BORDER_RIGHT_COLOR,
      ViewProps.BORDER_TOP_COLOR,
      ViewProps.BORDER_BOTTOM_COLOR,
      ViewProps.BORDER_START_COLOR,
      ViewProps.BORDER_END_COLOR,
      ViewProps.BORDER_BLOCK_COLOR,
      ViewProps.BORDER_BLOCK_END_COLOR,
      ViewProps.BORDER_BLOCK_START_COLOR,
      -> applyBorderColor(view, propName, value)

      else -> inner.setProperty(view, propName, value)
    }
  }

  override fun receiveCommand(
    view: SharedHeroView,
    commandName: String,
    args: ReadableArray,
  ) {
    inner.receiveCommand(view, commandName, args)
  }

  private fun applyBorderRadius(view: SharedHeroView, propName: String, value: Any?) {
    val prop = BORDER_RADIUS_PROPS.getValue(propName)
    val lp = LengthPercentage.setFromDynamic(DynamicFromObject(value))
    BackgroundStyleApplicator.setBorderRadius(view, prop, lp)
    // Mirror the all-corners radius onto the view so the flight engine reads it
    // back as physical pixels for corner interpolation. `LengthPercentage`
    // stores POINT values in CSS px (== dp on Android), so multiply by display
    // density to match the px-space geometry the rest of the pipeline uses.
    // Percentage radii are skipped (they'd need the resolved size, unavailable
    // at prop-set time) — the flight just uses 0 for those.
    if (prop == BorderRadiusProp.BORDER_RADIUS) {
      val dp = lp?.takeIf { it.type == LengthPercentageType.POINT }?.resolve(0f) ?: 0f
      view.cornerRadiusPx = PixelUtil.toPixelFromDIP(dp)
    }
  }

  private fun applyBorderWidth(view: SharedHeroView, propName: String, value: Any?) {
    val edge = BORDER_WIDTH_EDGES.getValue(propName)
    val width = (value as? Number)?.toFloat() ?: Float.NaN
    BackgroundStyleApplicator.setBorderWidth(view, edge, width)
  }

  private fun applyBorderColor(view: SharedHeroView, propName: String, value: Any?) {
    val edge = BORDER_COLOR_EDGES.getValue(propName)
    val color = (value as? Number)?.toInt()
    BackgroundStyleApplicator.setBorderColor(view, edge, color)
  }

  private companion object {
    val BORDER_RADIUS_PROPS: Map<String, BorderRadiusProp> = mapOf(
      ViewProps.BORDER_RADIUS to BorderRadiusProp.BORDER_RADIUS,
      ViewProps.BORDER_TOP_LEFT_RADIUS to BorderRadiusProp.BORDER_TOP_LEFT_RADIUS,
      ViewProps.BORDER_TOP_RIGHT_RADIUS to BorderRadiusProp.BORDER_TOP_RIGHT_RADIUS,
      ViewProps.BORDER_BOTTOM_RIGHT_RADIUS to BorderRadiusProp.BORDER_BOTTOM_RIGHT_RADIUS,
      ViewProps.BORDER_BOTTOM_LEFT_RADIUS to BorderRadiusProp.BORDER_BOTTOM_LEFT_RADIUS,
      ViewProps.BORDER_TOP_START_RADIUS to BorderRadiusProp.BORDER_TOP_START_RADIUS,
      ViewProps.BORDER_TOP_END_RADIUS to BorderRadiusProp.BORDER_TOP_END_RADIUS,
      ViewProps.BORDER_BOTTOM_START_RADIUS to BorderRadiusProp.BORDER_BOTTOM_START_RADIUS,
      ViewProps.BORDER_BOTTOM_END_RADIUS to BorderRadiusProp.BORDER_BOTTOM_END_RADIUS,
      ViewProps.BORDER_END_END_RADIUS to BorderRadiusProp.BORDER_END_END_RADIUS,
      ViewProps.BORDER_END_START_RADIUS to BorderRadiusProp.BORDER_END_START_RADIUS,
      ViewProps.BORDER_START_END_RADIUS to BorderRadiusProp.BORDER_START_END_RADIUS,
      ViewProps.BORDER_START_START_RADIUS to BorderRadiusProp.BORDER_START_START_RADIUS,
    )

    val BORDER_WIDTH_EDGES: Map<String, LogicalEdge> = mapOf(
      ViewProps.BORDER_WIDTH to LogicalEdge.ALL,
      ViewProps.BORDER_LEFT_WIDTH to LogicalEdge.LEFT,
      ViewProps.BORDER_RIGHT_WIDTH to LogicalEdge.RIGHT,
      ViewProps.BORDER_TOP_WIDTH to LogicalEdge.TOP,
      ViewProps.BORDER_BOTTOM_WIDTH to LogicalEdge.BOTTOM,
      ViewProps.BORDER_START_WIDTH to LogicalEdge.START,
      ViewProps.BORDER_END_WIDTH to LogicalEdge.END,
    )

    val BORDER_COLOR_EDGES: Map<String, LogicalEdge> = mapOf(
      ViewProps.BORDER_COLOR to LogicalEdge.ALL,
      ViewProps.BORDER_LEFT_COLOR to LogicalEdge.LEFT,
      ViewProps.BORDER_RIGHT_COLOR to LogicalEdge.RIGHT,
      ViewProps.BORDER_TOP_COLOR to LogicalEdge.TOP,
      ViewProps.BORDER_BOTTOM_COLOR to LogicalEdge.BOTTOM,
      ViewProps.BORDER_START_COLOR to LogicalEdge.START,
      ViewProps.BORDER_END_COLOR to LogicalEdge.END,
      ViewProps.BORDER_BLOCK_COLOR to LogicalEdge.BLOCK,
      ViewProps.BORDER_BLOCK_END_COLOR to LogicalEdge.BLOCK_END,
      ViewProps.BORDER_BLOCK_START_COLOR to LogicalEdge.BLOCK_START,
    )
  }
}
