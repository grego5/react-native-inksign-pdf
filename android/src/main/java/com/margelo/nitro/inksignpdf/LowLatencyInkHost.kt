package com.margelo.nitro.inksignpdf

import java.util.ArrayDeque

internal class LowLatencyInkCompletionQueue {
  private val lock = Any()
  private val entries = ArrayDeque<Entry>()

  private data class Entry(
    val acknowledgement: LowLatencyInkPresentationAcknowledgement?,
  )

  fun append(acknowledgement: LowLatencyInkPresentationAcknowledgement?) {
    synchronized(lock) { entries.addLast(Entry(acknowledgement)) }
  }

  fun removeFirst(): LowLatencyInkPresentationAcknowledgement? = synchronized(lock) {
    if (entries.isEmpty()) null else entries.removeFirst().acknowledgement
  }

  fun clear() {
    synchronized(lock) { entries.clear() }
  }
}

/** UI-thread seam used by the surface; AndroidX remains behind the presenter implementation. */
internal interface LowLatencyInkHost {
  val isAvailable: Boolean

  fun requestDraw(update: LowLatencyInkDrawRequest): Boolean
  fun handoff(
    generation: Long,
    sequence: Long,
    finalSnapshot: LowLatencyInkFinalSnapshot,
  ): Boolean = false
  fun drawDiagnostics(): LowLatencyInkDrawDiagnostics? = null
  fun handoffDiagnostics(): LowLatencyInkHandoffDiagnostics? = null
  fun resetActive(generation: Long)

  fun setPresentationAcknowledgementListener(
    listener: (LowLatencyInkPresentationAcknowledgement) -> Unit,
  ) = Unit

  fun setLifecycleCancellationListener(listener: () -> Unit) = Unit
}

internal object UnavailableLowLatencyInkHost : LowLatencyInkHost {
  override val isAvailable: Boolean = false

  override fun requestDraw(update: LowLatencyInkDrawRequest): Boolean = false

  override fun handoff(
    generation: Long,
    sequence: Long,
    finalSnapshot: LowLatencyInkFinalSnapshot,
  ): Boolean = false

  override fun drawDiagnostics(): LowLatencyInkDrawDiagnostics? = null

  override fun handoffDiagnostics(): LowLatencyInkHandoffDiagnostics? = null

  override fun resetActive(generation: Long) = Unit
}
