package com.margelo.nitro.inksignpdf

import android.graphics.Color

internal data class PenConfiguration(
  val color: Int,
  val minWidth: Double,
  val maxWidth: Double,
  val smoothing: Double,
) {
  /** Converts the public dp-sized nib into the page-space engine configuration. */
  fun inPageUnits(logicalDisplayUnitsPerPageUnit: Double): PenConfiguration {
    require(logicalDisplayUnitsPerPageUnit.isFinite() && logicalDisplayUnitsPerPageUnit > 0.0)
    return copy(
      minWidth = minWidth / logicalDisplayUnitsPerPageUnit,
      maxWidth = maxWidth / logicalDisplayUnitsPerPageUnit,
    )
  }

  companion object {
    internal val DEFAULT = PenConfiguration(
      // Keep default initialization usable in JVM tests without invoking an
      // Android framework method that is unavailable in the local stub.
      color = 0xFF0D0D0D.toInt(),
      minWidth = 2.0,
      maxWidth = 4.0,
      smoothing = 0.4,
    )

    fun sanitize(
      color: String?,
      minWidth: Double?,
      maxWidth: Double?,
      smoothing: Double?,
    ): PenConfiguration {
      var safeMinWidth = DEFAULT.minWidth
      var safeMaxWidth = DEFAULT.maxWidth
      var safeSmoothing = DEFAULT.smoothing
      if (minWidth != null && minWidth.isFinite() && minWidth > 0.0) safeMinWidth = minWidth
      if (maxWidth != null && maxWidth.isFinite() && maxWidth > 0.0) safeMaxWidth = maxWidth
      if (safeMinWidth > safeMaxWidth) {
        val swap = safeMinWidth
        safeMinWidth = safeMaxWidth
        safeMaxWidth = swap
      }
      if (smoothing != null && smoothing.isFinite()) safeSmoothing = smoothing.coerceIn(0.0, 1.0)
      return PenConfiguration(
        color = parseColor(color) ?: DEFAULT.color,
        minWidth = safeMinWidth,
        maxWidth = safeMaxWidth,
        smoothing = safeSmoothing,
      )
    }

    private fun parseColor(value: String?): Int? {
      if (value == null || value.length != 7 || value[0] != '#') return null
      val number = value.substring(1).toLongOrNull(16) ?: return null
      return Color.rgb(
        ((number shr 16) and 0xFF).toInt(),
        ((number shr 8) and 0xFF).toInt(),
        (number and 0xFF).toInt(),
      )
    }
  }
}
