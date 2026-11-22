package com.margelo.nitro.inksignpdf

import android.graphics.Color

/** Parses the public opaque RGB color contract, returning a caller default on invalid input. */
internal fun parseTextColor(value: String?, fallback: Int): Int {
  val candidate = value?.trim()
  if (candidate == null || candidate.length != 7 || candidate[0] != '#') return fallback
  return try {
    Color.parseColor(candidate)
  } catch (_: IllegalArgumentException) {
    fallback
  }
}

internal fun textUiColor(value: String?, fallback: Int, alpha: Int): Int {
  val parsed = parseTextColor(value, fallback)
  return Color.argb(alpha, Color.red(parsed), Color.green(parsed), Color.blue(parsed))
}
