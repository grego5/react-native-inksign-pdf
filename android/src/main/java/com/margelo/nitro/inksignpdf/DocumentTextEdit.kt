package com.margelo.nitro.inksignpdf

/** Core-owned current content; the editor retains only this transaction token. */
internal class DocumentTextEdit(
  val context: TextPageContext,
  val page: InkPageState,
  val id: Long,
  val baseline: TextAnnotation?,
  val initialOptions: TextAnnotationOptions?,
) {
  private val initialPlacement = page.history.textState.target(id).placementAnnotation
  val current: TextAnnotation? get() = page.history.textState.target(id).annotation
  var active = true
    private set

  fun update(annotation: TextAnnotation?) {
    check(active)
    check(annotation == null || annotation.id == id)
    page.history.applyTextState(id, annotation, baseline != annotation)
  }

  fun cancel() {
    end()
    if (baseline == null) page.history.textState.target(id).retainEmpty(initialPlacement)
  }

  fun end() {
    check(active)
    active = false
    page.history.finishTextState(id)
  }
}
