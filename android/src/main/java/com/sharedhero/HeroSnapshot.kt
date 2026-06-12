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
 * We sample a coarse grid spanning the whole bitmap rather than scanning every
 * pixel so this stays cheap enough to run at capture / flight-decision time.
 *
 * The grid must span the full area (not just the centre): text heroes are
 * sparse glyphs on a transparent background, so a few centre-band samples land
 * on the gaps between words/letters and false-positive a real line of text as
 * "blank". That misfire is expensive — it stops the snapshot from being stashed
 * and routes the flight through the in-place content-wait, desyncing sibling
 * heroes (e.g. a title firing immediately while its subtitle waits frames). Any
 * single opaque sample means real content, so a denser full-area grid only ever
 * makes us *less* likely to call something blank.
 */
internal fun isLikelyBlankBitmap(bitmap: Bitmap?): Boolean {
  if (bitmap == null || bitmap.isRecycled) return true
  val w = bitmap.width
  val h = bitmap.height
  if (w <= 0 || h <= 0) return true
  if (!bitmap.hasAlpha()) return false
  val steps = 10
  for (gy in 0 until steps) {
    val y = (((gy * 2 + 1) * h) / (steps * 2)).coerceIn(0, h - 1)
    for (gx in 0 until steps) {
      val x = (((gx * 2 + 1) * w) / (steps * 2)).coerceIn(0, w - 1)
      if (android.graphics.Color.alpha(bitmap.getPixel(x, y)) != 0) return false
    }
  }
  return true
}
