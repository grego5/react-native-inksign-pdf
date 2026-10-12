package com.margelo.nitro.inksignpdf

/** Main-thread reads borrowed from the core, with no mutable page/history/target ownership. */
internal interface DocumentReadState {
  val sourcePath: String
  val generation: Long
  val hasDocument: Boolean
  val pageCount: Int
  fun pageMetadata(index: Int): DocumentPageMetadata
  fun pageInfo(index: Int): PageInfo
  fun pageChangeEvent(index: Int): PageChangeEvent
  fun documentInfo(): DocumentState
  fun pageIndexForId(pageId: String): Int?
  fun pageSnapshot(index: Int): MutableDocumentCoordinator.PageSnapshot
  fun presentationSnapshot(): MutableDocumentCoordinator.Snapshot
  fun sessionInfo(): PdfSessionInfo
  fun pageHistoryRevision(index: Int): Long
  fun pageHistoryState(index: Int): InkState
  fun isDirty(): Boolean
  fun completedPagesSnapshot(): List<PdfPageContentSnapshot>
}

internal data class DocumentPageMetadata(
  val id: String,
  val dimensions: PdfPageDimensions,
  val geometryRevision: Long,
  val sourceDimensions: PdfPageDimensions,
  val tag: String?,
)

internal fun InkPageState.metadata() = DocumentPageMetadata(id, dimensions, geometryRevision, sourceDimensions, tag)
