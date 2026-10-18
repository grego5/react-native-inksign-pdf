package com.margelo.nitro.inksignpdf

/** Normalized request used by the shared target-construction pipeline. */
internal data class InputTargetResolutionOptions(
  val fieldName: String? = null,
  val bounds: TextAnnotationBounds? = null,
  val occurrence: TextKeyOccurrence? = null,
  val font: Variant_NullType_String? = null,
  val fontSize: Double? = null,
  val color: String? = null,
  val direction: TextDirection? = null,
  val maxLines: Double? = null,
  val alignment: TextAlignment? = null,
  val verticalAnchor: TextVerticalAnchor? = null,
)

internal fun ResolveInputUnderlineOptions.resolutionOptions() = InputTargetResolutionOptions(
  fieldName, bounds, occurrence, font, fontSize, color, direction, maxLines, alignment, verticalAnchor,
)

internal fun CreateInputAreaOptions.resolutionOptions() = InputTargetResolutionOptions(
  bounds = bounds, font = font, fontSize = fontSize, color = color, direction = direction,
  maxLines = maxLines, alignment = alignment, verticalAnchor = verticalAnchor,
)
