package com.margelo.nitro.inksignpdf

/** Describes whether AndroidX produced a batch that is safe to send to native prediction. */
internal enum class PredictionBatchStatus {
  ABSENT,
  INVALID,
  EMPTY,
  VALID,
}

internal object PredictionReplacementPolicy {
  /** Calls the native replacement only for a valid, non-empty prediction batch. */
  internal inline fun <T> replaceIfUsable(
    status: PredictionBatchStatus,
    inputCount: Int,
    replacement: () -> T,
  ): T? {
    return if (status == PredictionBatchStatus.VALID && inputCount > 0) {
      replacement()
    } else {
      null
    }
  }
}
