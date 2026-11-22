package com.margelo.nitro.inksignpdf

/** One current module value per core target; the empty fallback exists only after removal. */
internal class TextTargetState {
  var annotation: TextAnnotation? = null
    private set
  private var emptyAnnotation: TextAnnotation? = null
  val placementAnnotation: TextAnnotation? get() = annotation ?: emptyAnnotation

  internal fun retainEmpty(placement: TextAnnotation?) {
    check(annotation == null)
    emptyAnnotation = placement
  }

  internal fun apply(next: TextAnnotation?) {
    if (next == null) {
      if (annotation != null) emptyAnnotation = annotation
    } else emptyAnnotation = null
    annotation = next
  }
}

/** Page-owned state application boundary shared by edits and history restoration. */
internal class PageTextState {
  private val targets = LinkedHashMap<Long, TextTargetState>()
  fun target(id: Long): TextTargetState = targets.getOrPut(id) { TextTargetState() }
  fun apply(states: List<TextAnnotation>) {
    val next = states.associateBy { it.id }
    targets.forEach { (id, state) -> state.apply(next[id]) }
    states.forEach { if (it.id !in targets) target(it.id).apply(it) }
  }
  fun apply(id: Long, annotation: TextAnnotation?) {
    check(annotation == null || annotation.id == id)
    target(id).apply(annotation)
  }
}
