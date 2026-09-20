package com.margelo.nitro.inksignpdf

import kotlin.math.max

/**
 * Presenter-owned lifetime for heavyweight draw data submitted through the AndroidX token queue.
 *
 * Publication happens on the UI thread and resolution/completion happens on the AndroidX worker.
 * The lock protects the maps and counters; the payload itself is immutable after publication.
 */
internal class LowLatencyInkPayloadMailbox {
  private val lock = Any()
  private var pendingToken: LowLatencyInkRenderToken? = null
  private var pendingRequest: LowLatencyInkDrawRequest? = null
  private var executingToken: LowLatencyInkRenderToken? = null
  private var executingRequest: LowLatencyInkDrawRequest? = null
  private var publishedPayloadCount = 0L
  private var resolvedPayloadCount = 0L
  private var missingPayloadCount = 0L
  private var peakPendingPayloadCount = 0
  private var supersededPayloadCount = 0L

  fun publish(request: LowLatencyInkDrawRequest): LowLatencyInkRenderToken {
    val token = LowLatencyInkRenderToken(request.generation, request.sequence)
    val snapshot = synchronized(lock) {
      check(token != pendingToken && token != executingToken) {
        "Duplicate front-buffer render token: $token"
      }
      pendingRequest?.let { superseded ->
        check(request.dirtyRegion.contains(superseded.dirtyRegion)) {
          "Replacement payload ${request.sequence} does not contain superseded dirty region"
        }
        supersededPayloadCount += 1L
      }
      pendingToken = token
      pendingRequest = request
      publishedPayloadCount += 1L
      peakPendingPayloadCount = max(peakPendingPayloadCount, 1)
      snapshotLocked()
    }
    report(snapshot)
    return token
  }

  /** Remove a payload when AndroidX rejected the token before retaining it. */
  fun discardPending(token: LowLatencyInkRenderToken) {
    val snapshot = synchronized(lock) {
      if (pendingToken == token) {
        pendingToken = null
        pendingRequest = null
      }
      snapshotLocked()
    }
    report(snapshot)
  }

  /** Resolve exactly one published payload and transfer its ownership to the worker callback. */
  fun resolve(token: LowLatencyInkRenderToken): LowLatencyInkDrawRequest? {
    val result = synchronized(lock) {
      val request = pendingRequest
      val resolved = if (pendingToken != token || request == null) {
        missingPayloadCount += 1L
        null
      } else {
        check(executingRequest == null) { "Front-buffer callbacks executed concurrently" }
        pendingToken = null
        pendingRequest = null
        executingToken = token
        executingRequest = request
        resolvedPayloadCount += 1L
        request
      }
      resolved to snapshotLocked()
    }
    report(result.second)
    return result.first
  }

  /** Release the worker-owned payload after the callback has finished, including failures. */
  fun complete(token: LowLatencyInkRenderToken) {
    val snapshot = synchronized(lock) {
      if (executingToken == token) {
        executingToken = null
        executingRequest = null
      }
      snapshotLocked()
    }
    report(snapshot)
  }

  /** Drop queued and executing ownership during reset, cancellation, release, or disposal. */
  fun clear() {
    val snapshot = synchronized(lock) {
      pendingToken = null
      pendingRequest = null
      executingToken = null
      executingRequest = null
      snapshotLocked()
    }
    report(snapshot)
  }

  fun diagnostics(): LowLatencyInkPayloadDiagnostics = synchronized(lock) {
    snapshotLocked()
  }

  private fun snapshotLocked() = LowLatencyInkPayloadDiagnostics(
    publishedPayloadCount = publishedPayloadCount,
    resolvedPayloadCount = resolvedPayloadCount,
    missingPayloadCount = missingPayloadCount,
    executingPayloadCount = if (executingRequest == null) 0 else 1,
    pendingPayloadCount = if (pendingRequest == null) 0 else 1,
    peakPendingPayloadCount = peakPendingPayloadCount,
    supersededPayloadCount = supersededPayloadCount,
  )

  private fun report(snapshot: LowLatencyInkPayloadDiagnostics) {
    InkPerfetto.counter(
      "InkSign front-buffer published payloads",
      snapshot.publishedPayloadCount,
    )
    InkPerfetto.counter(
      "InkSign front-buffer resolved payloads",
      snapshot.resolvedPayloadCount,
    )
    InkPerfetto.counter(
      "InkSign front-buffer missing payloads",
      snapshot.missingPayloadCount,
    )
    InkPerfetto.counter(
      "InkSign front-buffer executing payloads",
      snapshot.executingPayloadCount,
    )
    InkPerfetto.counter(
      "InkSign front-buffer pending payloads",
      snapshot.pendingPayloadCount,
    )
    InkPerfetto.counter(
      "InkSign front-buffer peak pending payloads",
      snapshot.peakPendingPayloadCount,
    )
    InkPerfetto.counter(
      "InkSign front-buffer superseded payloads",
      snapshot.supersededPayloadCount,
    )
  }
}
