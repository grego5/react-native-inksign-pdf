package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PredictionReplacementPolicyTest {
  @Test
  fun nullPredictionSkipsNativeReplacement() {
    assertSkipped(PredictionBatchStatus.ABSENT, inputCount = 0)
  }

  @Test
  fun invalidPredictionSkipsNativeReplacement() {
    assertSkipped(PredictionBatchStatus.INVALID, inputCount = 0)
  }

  @Test
  fun emptyPredictionSkipsNativeReplacement() {
    assertSkipped(PredictionBatchStatus.EMPTY, inputCount = 0)
  }

  @Test
  fun validPredictionCallsNativeReplacementExactlyOnce() {
    var replacementCount = 0

    val result = PredictionReplacementPolicy.replaceIfUsable(
      PredictionBatchStatus.VALID,
      inputCount = 1,
    ) {
      replacementCount += 1
      "prediction-frame"
    }

    assertEquals("prediction-frame", result)
    assertEquals(1, replacementCount)
  }

  private fun assertSkipped(status: PredictionBatchStatus, inputCount: Int) {
    var replacementCount = 0

    val result = PredictionReplacementPolicy.replaceIfUsable(status, inputCount) {
      replacementCount += 1
      "prediction-frame"
    }

    assertNull(result)
    assertEquals(0, replacementCount)
  }
}
