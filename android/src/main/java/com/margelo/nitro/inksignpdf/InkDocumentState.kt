package com.margelo.nitro.inksignpdf

/** UI-thread-owned state for one loaded PDF document. */
internal class InkDocumentState(
  val sourcePath: String,
  val generation: Long,
  pages: List<PdfPageDimensions>,
) {
  val pages: List<InkPageState> = pages.map { dimensions ->
    InkPageState(dimensions)
  }
  var activePageIndex: Int = 0
    private set

  init {
    require(sourcePath.isNotEmpty())
    require(this.pages.isNotEmpty())
  }

  val pageCount: Int
    get() = pages.size

  fun page(index: Int): InkPageState {
    require(index in pages.indices)
    return pages[index]
  }

  fun setActivePage(index: Int) {
    require(index in pages.indices)
    activePageIndex = index
  }

  fun sessionInfo(): PdfSessionInfo {
    return PdfSessionInfo(
      sourcePath = sourcePath,
      pages = pages.map { it.dimensions },
      generation = generation,
    )
  }
}

/** UI-thread-owned state for one document page with local ordered page content. */
internal class InkPageState(
  val dimensions: PdfPageDimensions,
) {
  val history = InkHistory()
}

internal data class PdfPageContentSnapshot(
  val pageIndex: Int,
  val dimensions: PdfPageDimensions,
  val content: List<PageContent>,
) {
  /** Ink-only projection for consumers that do not yet render text. */
  val strokes: List<StrokeOutline>
    get() = content.mapNotNull { entry ->
      (entry as? PageContent.Ink)?.outline
    }
}

internal data class PdfPageInfo(
  val pageIndex: Int,
  val pageCount: Int,
  val dimensions: PdfPageDimensions,
)
