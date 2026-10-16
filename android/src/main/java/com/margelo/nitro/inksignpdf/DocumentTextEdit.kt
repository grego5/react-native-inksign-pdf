package com.margelo.nitro.inksignpdf

/** Core-owned current content; the editor retains only this transaction token. */
internal class DocumentTextEdit(
  val context: TextPageContext,
  val page: InkPageState,
  val id: Long,
  val baseline: TextAnnotation?,
) {
  var current: TextAnnotation? = baseline
    private set
  var active = true
    private set

  fun update(annotation: TextAnnotation?) {
    check(active)
    check(annotation == null || annotation.id == id)
    current = annotation
    page.history.textPreview = PageContentHistory.TextPreview(id, annotation, baseline != annotation)
  }

  fun end() {
    check(active)
    active = false
    page.history.textPreview = null
  }
}
