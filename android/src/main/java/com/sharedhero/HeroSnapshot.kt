package com.sharedhero

import android.graphics.Bitmap
import android.graphics.Rect

/**
 * Immutable capture of a [SharedHeroView]'s appearance at a single moment in
 * time. Taken by the registry the instant a twin appears, so the flight can
 * run against a known-good source state even when the host navigator has
 * already animated the source view off-screen by the time the flight starts.
 */
data class HeroSnapshot(
  val bitmap: Bitmap?,
  val rect: Rect,
  val cornerRadius: Float,
  val backgroundColor: Int,
)

/**
 * Cheap heuristic for a fully-transparent ("blank") snapshot bitmap.
 *
 * Two situations produce a correctly-sized but empty bitmap:
 *  - A hero captured on a frame before its child `<Image>` (Fresco) has
 *    painted — the cold-launch case where the first toggle would otherwise
 *    fly an invisible overlay.
 *  - A live render of a view whose child `<Image>` has already released its
 *    drawable while detaching.
 *
 * We sample a few points near the centre rather than scanning every pixel so
 * this stays cheap enough to run at capture / flight-decision time. A real
 * hero always has opaque pixels near its centre, so this never
 * false-positives on genuine content.
 */
internal fun isLikelyBlankBitmap(bitmap: Bitmap?): Boolean {
  if (bitmap == null || bitmap.isRecycled) return true
  val w = bitmap.width
  val h = bitmap.height
  if (w <= 0 || h <= 0) return true
  if (!bitmap.hasAlpha()) return false
  val xs = intArrayOf(w / 2, w / 4, (w * 3) / 4, w / 2, w / 2)
  val ys = intArrayOf(h / 2, h / 2, h / 2, h / 4, (h * 3) / 4)
  for (i in xs.indices) {
    val x = xs[i].coerceIn(0, w - 1)
    val y = ys[i].coerceIn(0, h - 1)
    if (android.graphics.Color.alpha(bitmap.getPixel(x, y)) != 0) return false
  }
  return true
}
