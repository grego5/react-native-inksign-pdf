package com.margelo.nitro.inksignpdf

/** Main-thread viewer selection over document reads borrowed from the core. */
internal class ViewerDocumentState(private val document: DocumentReadState) : DocumentReadState by document {
  private var selectedPageId: String? = if (document.hasDocument) document.pageMetadata(0).id else null
  private var selectedIndex = 0
  private var publishedPageCount = document.pageCount

  override val hasDocument: Boolean
    get() = document.hasDocument && selectedPageId != null

  val activePageIndex: Int
    get() = checkNotNull(selectedPageId?.let(document::pageIndexForId)) {
      "Viewer selection is not present in the document"
    }

  fun activePageId(): String = checkNotNull(selectedPageId)
  fun activeHistoryState(): InkState = document.pageHistoryState(activePageIndex)

  fun activatePage(index: Int): DocumentCoordinator.PageSnapshot {
    val page = document.pageSnapshot(index)
    selectedPageId = page.id
    selectedIndex = index
    return page
  }

  fun opened() {
    activatePage(0)
    publishedPageCount = document.pageCount
  }

  fun cleared() {
    selectedPageId = null
    selectedIndex = 0
    publishedPageCount = 0
  }

  /** Preserve identity on reorder/rotation; select the next surviving page after deletion. */
  fun pagesPublished() {
    val index = selectedPageId?.let(document::pageIndexForId)
      ?: selectedIndex.coerceAtMost(document.pageCount - 1)
    activatePage(index)
    publishedPageCount = document.pageCount
  }
}
