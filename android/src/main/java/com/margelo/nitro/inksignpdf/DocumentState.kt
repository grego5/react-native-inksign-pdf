package com.margelo.nitro.inksignpdf

/** Stable identity and dimensions captured before a structural candidate runs. */
internal data class PageRecord(
  val id: String,
  val dimensions: PdfPageDimensions,
) {
  companion object {
    fun newId(): String = java.util.UUID.randomUUID().toString()
  }
}

/** UI-thread-owned state for one document page with local ordered page content. */
internal class InkPageState(
  val id: String,
  val dimensions: PdfPageDimensions,
) {
  constructor(dimensions: PdfPageDimensions) : this(PageRecord.newId(), dimensions)

  val history = InkHistory()
}

internal data class PdfPageContentSnapshot(
  val pageIndex: Int,
  val dimensions: PdfPageDimensions,
  val content: List<PageContent>,
) {
  /** Ink-only projection for consumers that do not yet render text. */
  val strokes: List<StrokeOutline>
    get() = content.mapNotNull { it.inkOutlineOrNull() }
}

internal data class PdfPageInfo(
  val pageIndex: Int,
  val pageCount: Int,
  val dimensions: PdfPageDimensions,
)
