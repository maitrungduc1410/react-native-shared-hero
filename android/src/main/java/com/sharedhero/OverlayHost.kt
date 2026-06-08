package com.sharedhero

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.View
import android.view.ViewGroup
import android.view.ViewGroupOverlay

/**
 * Resolves the [ViewGroupOverlay] used to host flying snapshots so they sit
 * above the normal view hierarchy (and most popups).
 *
 * The decor view is a `ViewGroup`, so its overlay is a `ViewGroupOverlay`,
 * which accepts both `Drawable` and `View` children. A plain `View.overlay`
 * only accepts drawables.
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
   * Resolves the overlay from [view]'s OWN window rather than the host
   * Activity's window. This matters for cross-window destinations: RN's core
   * `<Modal>` renders into a SEPARATE Dialog window (its own `DecorView`) that
   * is layered ABOVE the host Activity's window. A forward flight whose
   * destination lives in that Dialog must host its snapshot in the Dialog's
   * decor, otherwise the snapshot is added to the Activity decor — BELOW the
   * Dialog window — and the flight animates entirely occluded behind the modal
   * (the user sees only a blanked destination, then the image "pops" in when
   * the destination is un-hidden at flight end).
   *
   * For same-window flights (native-stack push/pop, in-place toggles, and the
   * core-Modal DISMISS whose destination is the list thumbnail back in the
   * Activity window) the view's root view IS the Activity decor, so this
   * resolves to exactly the same overlay as [resolveOverlay] and is a no-op
   * change. We fall back to the context-based resolver if the attached root
   * isn't a usable `ViewGroup`.
   *
   * `view.rootView` returns the topmost view of the window the view is
   * currently attached to (the window's `DecorView`), so its overlay sits
   * above all of that window's content.
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
