package com.margelo.nitro.inksignpdf

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class LowLatencyInkPayloadMailboxTest : LowLatencyInkPresenterTestBase() {
  @Test
  fun mailboxRetainsOnlyOneExecutingAndOneLatestPendingPayload() {
    val mailbox = LowLatencyInkPayloadMailbox()
    val first = mailbox.publish(drawRequest(sequence = 1L, generation = 1L))
    val second = mailbox.publish(drawRequest(sequence = 2L, generation = 1L))

    assertEquals(1, mailbox.diagnostics().pendingPayloadCount)
    assertEquals(1, mailbox.diagnostics().peakPendingPayloadCount)
    assertEquals(1L, mailbox.diagnostics().supersededPayloadCount)
    assertEquals(null, mailbox.resolve(first))
    assertTrue(mailbox.resolve(second) != null)
    assertEquals(0, mailbox.diagnostics().pendingPayloadCount)
    assertEquals(1, mailbox.diagnostics().executingPayloadCount)
    mailbox.complete(second)
    assertEquals(0, mailbox.diagnostics().executingPayloadCount)
    assertEquals(1L, mailbox.diagnostics().resolvedPayloadCount)
  }

  @Test
  fun clearedGenerationCannotResolveAnOldToken() {
    val mailbox = LowLatencyInkPayloadMailbox()
    val oldToken = mailbox.publish(drawRequest(sequence = 1L, generation = 1L))
    mailbox.clear()
    val newToken = mailbox.publish(drawRequest(sequence = 1L, generation = 2L))

    assertEquals(null, mailbox.resolve(oldToken))
    assertTrue(mailbox.resolve(newToken) != null)
    assertEquals(1L, mailbox.diagnostics().missingPayloadCount)
    assertEquals(1, mailbox.diagnostics().executingPayloadCount)
    mailbox.complete(newToken)
    assertEquals(0, mailbox.diagnostics().executingPayloadCount)
  }

  @Test
  fun supersededTokenCannotConsumeTheLatestPayload() {
    val mailbox = LowLatencyInkPayloadMailbox()
    val first = mailbox.publish(drawRequest(sequence = 1L, generation = 1L))
    val second = mailbox.publish(drawRequest(sequence = 2L, generation = 1L))

    assertEquals(null, mailbox.resolve(first))
    assertEquals(1, mailbox.diagnostics().pendingPayloadCount)
    assertTrue(mailbox.resolve(second) != null)
    mailbox.complete(second)
    assertEquals(1L, mailbox.diagnostics().missingPayloadCount)
    assertEquals(0, mailbox.diagnostics().pendingPayloadCount)
    assertEquals(0, mailbox.diagnostics().executingPayloadCount)
  }

  @Test
  fun mailboxRejectsAReplacementThatDoesNotRebuildTheSupersededRegion() {
    val mailbox = LowLatencyInkPayloadMailbox()
    mailbox.publish(rectDrawRequest(1L, 10, 10, 20, 20))

    try {
      mailbox.publish(rectDrawRequest(2L, 100, 100, 110, 110))
      throw AssertionError("Expected a non-self-sufficient replacement to fail")
    } catch (_: IllegalStateException) {
      assertEquals(1, mailbox.diagnostics().pendingPayloadCount)
    }
  }

  @Test
  fun completionQueuePreservesNoAckAndSuccessfulEntriesInCallbackOrder() {
    val queue = LowLatencyInkCompletionQueue()
    val acknowledgement = LowLatencyInkPresentationAcknowledgement(3L, 7L, 11L)

    queue.append(null)
    queue.append(acknowledgement)

    assertEquals(null, queue.removeFirst())
    assertEquals(acknowledgement, queue.removeFirst())
    assertEquals(null, queue.removeFirst())
  }
}
