package com.margelo.nitro.inksignpdf

/** UI-thread-owned coordinator for one published mutable PDF document. */
internal class MutableDocumentCoordinator(
  var sourcePath: String,
  val generation: Long,
  pages: List<PdfPageDimensions>,
) {
  val pages: MutableList<InkPageState> = pages.map { dimensions ->
    InkPageState(PageRecord.newId(), dimensions)
  }.toMutableList()
  private var activePageId: String = checkNotNull(this.pages.firstOrNull()).id
  var structuralDirty: Boolean = false
    private set

  init {
    require(sourcePath.isNotEmpty())
    require(this.pages.isNotEmpty())
  }

  val activePageIndex: Int
    get() = pages.indexOfFirst { it.id == activePageId }.also { index ->
      check(index >= 0) { "Active page is not present in the document" }
    }

  val pageCount: Int
    get() = pages.size

  fun page(index: Int): InkPageState {
    require(index in pages.indices)
    return pages[index]
  }

  fun setActivePage(index: Int) {
    require(index in pages.indices)
    activePageId = pages[index].id
  }

  fun installCandidate(
    candidatePath: String,
    candidatePages: List<InkPageState>,
    candidateActivePageId: String,
  ) {
    require(candidatePath.isNotEmpty())
    require(candidatePages.isNotEmpty())
    require(candidatePages.any { it.id == candidateActivePageId })
    sourcePath = candidatePath
    pages.clear()
    pages.addAll(candidatePages)
    activePageId = candidateActivePageId
    structuralDirty = true
  }

  data class StructuralCandidate(
    val pages: List<InkPageState>,
    val activePageId: String,
  )

  fun appendCandidate(dimensions: List<PdfPageDimensions>): StructuralCandidate {
    require(dimensions.isNotEmpty())
    val appended = dimensions.map { InkPageState(PageRecord.newId(), it) }
    return StructuralCandidate(pages.toList() + appended, appended.first().id)
  }

  fun removeActiveCandidate(): StructuralCandidate {
    check(pageCount > 1) { "The document must retain one page" }
    val next = pages.toMutableList().also { it.removeAt(activePageIndex) }
    val targetIndex = activePageIndex.coerceAtMost(next.lastIndex)
    return StructuralCandidate(next, next[targetIndex].id)
  }

  fun moveActiveCandidate(destination: Int): StructuralCandidate {
    require(destination in pages.indices)
    val source = activePageIndex
    if (source == destination) return StructuralCandidate(pages.toList(), activePageId)
    val next = pages.toMutableList().also {
      val moved = it.removeAt(source)
      it.add(destination, moved)
    }
    return StructuralCandidate(next, activePageId)
  }

  fun markStructuralDirty() {
    structuralDirty = true
  }

  fun pageRecords(): List<PageRecord> = pages.map { page ->
    PageRecord(page.id, page.dimensions)
  }

  fun activePageId(): String = activePageId

  fun sessionInfo(): PdfSessionInfo {
    return PdfSessionInfo(
      sourcePath = sourcePath,
      pages = pages.map { it.dimensions },
      generation = generation,
    )
  }
}

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
    get() = content.mapNotNull { entry ->
      (entry as? PageContent.Ink)?.outline
    }
}

internal data class PdfPageInfo(
  val pageIndex: Int,
  val pageCount: Int,
  val dimensions: PdfPageDimensions,
)
