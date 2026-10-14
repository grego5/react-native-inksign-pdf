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

/** Detached presentation metadata; owns no document or worker resources. */
internal object DetachedDocumentReadState : DocumentReadState {
  override val sourcePath = ""
  override val generation = 0L
  override val hasDocument = false
  override val pageCount = 0
  private fun unavailable(): Nothing = throw PdfSessionException("view_not_ready", "No document is attached")
  override fun pageMetadata(index: Int): DocumentPageMetadata = unavailable()
  override fun pageInfo(index: Int): PageInfo = unavailable()
  override fun pageChangeEvent(index: Int): PageChangeEvent = unavailable()
  override fun documentInfo() = DocumentState(null, 0.0, false)
  override fun pageIndexForId(pageId: String): Int? = null
  override fun pageSnapshot(index: Int): MutableDocumentCoordinator.PageSnapshot = unavailable()
  override fun presentationSnapshot(): MutableDocumentCoordinator.Snapshot = unavailable()
  override fun sessionInfo(): PdfSessionInfo = unavailable()
  override fun pageHistoryRevision(index: Int): Long = unavailable()
  override fun pageHistoryState(index: Int): InkState = unavailable()
  override fun isDirty() = false
  override fun completedPagesSnapshot() = emptyList<PdfPageContentSnapshot>()
}

internal fun InkPageState.metadata() = DocumentPageMetadata(id, dimensions, geometryRevision, sourceDimensions, tag)
