package com.sharedhero

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.View
import android.view.ViewGroup
import android.view.ViewGroupOverlay

/**
 * Resolves the [ViewGroupOverlay] used to host flying snapshots above the
 * normal view hierarchy (and most popups).
 *
 * The decor view is a `ViewGroup`, so its overlay is a `ViewGroupOverlay`,
 * which accepts `View` children (a plain `View.overlay` accepts only drawables).
 */
object OverlayHost {
  /** Returns the activity decor's overlay or null if [context] isn't activity-bound. */
  fun resolveOverlay(context: Context): ViewGroupOverlay? {
    val activity = activityOf(context) ?: return null
    val window = activity.window ?: return null
    val decor = window.decorView as? ViewGroup ?: return null
    return decor.overlay
  }

  /**
   * Resolves the overlay from [view]'s OWN window, not the host Activity's.
   * Matters for cross-window destinations: RN's core `<Modal>` renders into a
   * SEPARATE Dialog window (its own `DecorView`) layered ABOVE the Activity
   * window. A forward flight into that Dialog must host its snapshot in the
   * Dialog's decor; otherwise it's added to the Activity decor — BELOW the
   * Dialog — and animates entirely occluded behind the modal (user sees a
   * blanked dest, then the image "pops" in when the dest un-hides at flight end).
   *
   * For same-window flights (native-stack push/pop, in-place toggles, and the
   * core-Modal DISMISS back to the Activity-window list thumbnail) `rootView`
   * IS the Activity decor, so this matches [resolveOverlay] exactly. Falls back
   * to the context-based resolver if the attached root isn't a usable
   * `ViewGroup`. (`view.rootView` is the window's `DecorView`, so its overlay
   * sits above all of that window's content.)
   */
  fun resolveOverlay(view: View): ViewGroupOverlay? {
    if (view.isAttachedToWindow) {
      (view.rootView as? ViewGroup)?.let { return it.overlay }
    }
    return resolveOverlay(view.context)
  }

  private fun activityOf(context: Context): Activity? {
    var c: Context? = context
    while (c is ContextWrapper) {
      if (c is Activity) return c
      c = c.baseContext
    }
    return null
  }
}
