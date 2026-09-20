package com.margelo.nitro.inksignpdf

import kotlin.math.floor

/** Immutable identity for one target-page snapshot request. */
internal data class PagePreviewKey(
  val generation: Long,
  val sourcePageIndex: Int,
  val targetPageIndex: Int,
  val direction: SwipeDirection,
  val targetZoom: Double,
  val targetFocus: PagePoint,
  val targetContentRevision: Long,
  val viewportWidthPx: Int,
  val viewportHeightPx: Int,
  val density: Double,
)

/** Target mapping and render request used by the transient preview. */
internal data class PagePreviewRequest(
  val key: PagePreviewKey,
  val request: PdfTileRequest,
  val targetTransform: PageTransform,
  val targetPage: PdfPageDimensions,
  val bitmapLeftPx: Double,
  val bitmapTopPx: Double,
  val inkPaths: List<InkPathData>,
  val textAnnotations: List<TextAnnotation>,
  val textLayer: TextRenderLayer,
)

internal fun pagePreviewRequest(
  generation: Long,
  pageSwitchId: Long,
  sourcePageIndex: Int,
  targetPageIndex: Int,
  direction: SwipeDirection,
  targetPage: PdfPageDimensions,
  targetZoom: Double,
  targetFocus: PagePoint,
  targetContentRevision: Long,
  viewportWidthPx: Int,
  viewportHeightPx: Int,
  density: Double,
  inkPaths: List<InkPathData>,
  textAnnotations: List<TextAnnotation> = emptyList(),
): PagePreviewRequest? {
  if (generation < 0L || pageSwitchId < 0L || sourcePageIndex < 0 || targetPageIndex < 0 ||
    !targetPage.width.isFinite() || targetPage.width <= 0.0 ||
    !targetPage.height.isFinite() || targetPage.height <= 0.0 ||
    !targetZoom.isFinite() || targetZoom <= 0.0 ||
    !targetFocus.x.isFinite() || !targetFocus.y.isFinite() || targetContentRevision < 0L ||
    viewportWidthPx <= 0 || viewportHeightPx <= 0 ||
    !density.isFinite() || density <= 0.0
  ) return null

  val viewport = PageViewport(
    targetPage,
    ViewportSize(viewportWidthPx.toDouble(), viewportHeightPx.toDouble(), density),
  )
  viewport.setViewport(targetZoom, targetFocus)
  val state = viewport.state
  val scale = state.pageToView.uniformScale() ?: return null
  val viewOffsetX = state.pageToView.tx
  val viewOffsetY = state.pageToView.ty
  val leftPx = floor(-viewOffsetX).toLong()
  val topPx = floor(-viewOffsetY).toLong()
  if (leftPx !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() ||
    topPx !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()
  ) return null
  val key = PagePreviewKey(
    generation = generation,
    sourcePageIndex = sourcePageIndex,
    targetPageIndex = targetPageIndex,
    direction = direction,
    targetZoom = state.zoom,
    targetFocus = state.focus,
    targetContentRevision = targetContentRevision,
    viewportWidthPx = viewportWidthPx,
    viewportHeightPx = viewportHeightPx,
    density = density,
  )
  val request = PdfTileRequest(
    key = PdfTileKey(
      generation = generation,
      pageSwitchId = pageSwitchId,
      pageIndex = targetPageIndex,
      level = 0,
      x = 0,
      y = 0,
    ),
    leftPx = leftPx.toInt(),
    topPx = topPx.toInt(),
    widthPx = viewportWidthPx,
    heightPx = viewportHeightPx,
    scale = scale,
    priority = androidPdfTileVisiblePriority,
  )
  return PagePreviewRequest(
    key = key,
    request = request,
    targetTransform = state.pageToView,
    targetPage = targetPage,
    bitmapLeftPx = viewOffsetX + leftPx,
    bitmapTopPx = viewOffsetY + topPx,
    inkPaths = inkPaths.toList(),
    textAnnotations = textAnnotations.toList(),
    textLayer = TextRenderLayer.empty(),
  )
}

internal fun PagePreviewRequest.targetPageRect(): PageRect {
  val topLeft = targetTransform.map(PagePoint(0.0, 0.0))
  val bottomRight = targetTransform.map(PagePoint(targetPage.width, targetPage.height))
  return PageRect(
    left = minOf(topLeft.x, bottomRight.x),
    top = minOf(topLeft.y, bottomRight.y),
    right = maxOf(topLeft.x, bottomRight.x),
    bottom = maxOf(topLeft.y, bottomRight.y),
  )
}

internal data class PageRect(
  val left: Double,
  val top: Double,
  val right: Double,
  val bottom: Double,
)
