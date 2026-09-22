package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class MutableDocumentCoordinatorTest {
  @Test
  fun pageIdsRemainStableAcrossMoveAndRemovalCandidate() {
    val coordinator = coordinator()
    val original = coordinator.pages.map { it.id }

    val moved = coordinator.moveActiveCandidate(0)
    assertEquals(original[1], moved.pages[0].id)
    assertEquals(original[0], moved.pages[1].id)
    assertEquals(original[1], moved.activePageId)

    coordinator.setActivePage(1)
    val removed = coordinator.removeActiveCandidate()
    assertEquals(listOf(original[0], original[2]), removed.pages.map { it.id })
    assertEquals(original[2], removed.activePageId)
  }

  @Test
  fun appendCandidateCreatesFreshIdsAndDoesNotPublishState() {
    val coordinator = coordinator()
    val before = coordinator.pages.map { it.id }
    val candidate = coordinator.appendCandidate(listOf(PdfPageDimensions(400.0, 500.0)))

    assertEquals(before, coordinator.pages.map { it.id })
    assertEquals(3, candidate.pages.size)
    assertNotEquals(before.last(), candidate.pages.last().id)
    assertEquals(candidate.pages.last().id, candidate.activePageId)
    assertTrue(!coordinator.structuralDirty)
  }

  @Test
  fun publicationMarksStructuralDirtyWithoutChangingPageHistory() {
    val coordinator = coordinator()
    val histories = coordinator.pages.associate { it.id to it.history }
    val candidate = coordinator.moveActiveCandidate(0)
    coordinator.installCandidate("working.pdf", candidate.pages, candidate.activePageId)

    assertTrue(coordinator.structuralDirty)
    assertEquals(candidate.activePageId, coordinator.pages[coordinator.activePageIndex].id)
    coordinator.pages.forEach { page -> assertTrue(histories[page.id] === page.history) }
  }

  @Test
  fun removingANeighborRetainsEverySurvivingPageHistory() {
    val coordinator = coordinator()
    val retained = coordinator.pages[0]
    val trailing = coordinator.pages[2]

    val candidate = coordinator.removeActiveCandidate()
    coordinator.installCandidate("candidate.pdf", candidate.pages, candidate.activePageId)

    assertTrue(coordinator.pages[0] === retained)
    assertTrue(coordinator.pages[1] === trailing)
  }

  @Test
  fun removeCandidateRejectsTheSolePage() {
    val coordinator = MutableDocumentCoordinator(
      sourcePath = "working.pdf",
      generation = 1L,
      pages = listOf(PdfPageDimensions(100.0, 100.0)),
      sessionWorker = PdfSessionWorker(),
      artifactPolicy = TestDocumentArtifactPolicy(),
    )
    try {
      coordinator.removeActiveCandidate()
      fail("Expected the last page to be required")
    } catch (error: IllegalStateException) {
      assertTrue(error.message.orEmpty().contains("retain one page"))
    }
  }

  @Test
  fun operationAdmissionHasOneCoordinatorOwner() {
    val coordinator = coordinator()
    val operation = coordinator.beginOperation()
    try {
      coordinator.beginOperation()
      fail("Expected the second document operation to be rejected")
    } catch (error: PdfSessionException) {
      assertEquals("operation_in_progress", error.code)
    } finally {
      coordinator.endOperation(operation)
    }
    val nextOperation = coordinator.beginOperation().also {
      coordinator.endOperation(it)
    }
    assertTrue(nextOperation > operation)
  }

  @Test
  fun operationIsReservedBeforePreflightCanReenter() {
    val coordinator = coordinator()
    var reentrantError: PdfSessionException? = null

    val operation = coordinator.beginOperation {
      try {
        coordinator.beginOperation()
      } catch (error: PdfSessionException) {
        reentrantError = error
      }
    }

    assertEquals("operation_in_progress", reentrantError?.code)
    coordinator.endOperation(operation)
  }

  @Test
  fun failedPreflightReleasesItsReservation() {
    val coordinator = coordinator()

    try {
      coordinator.beginOperation { error("preflight failed") }
      fail("Expected preflight failure")
    } catch (_: IllegalStateException) {
      // Expected.
    }

    coordinator.beginOperation().also(coordinator::endOperation)
  }

  @Test
  fun snapshotIsDetachedFromPublishedPageCollection() {
    val coordinator = coordinator()
    val snapshot = coordinator.snapshot()
    assertEquals(coordinator.pageCount, snapshot.pages.size)
    assertEquals(coordinator.activePageIndex, snapshot.activePageIndex)
    assertEquals(coordinator.pages.map { it.id }, snapshot.pages.map { it.id })
    assertEquals(coordinator.sourcePath, snapshot.sourcePath)
  }

  @Test
  fun aggregateValidationRejectsPageOrderThatDoesNotMatchPdfiumMetadata() {
    val coordinator = coordinator()
    val candidate = coordinator.moveActiveCandidate(0)
    val unchangedInfo = coordinator.sessionInfo()

    try {
      coordinator.validateCandidateAggregate(unchangedInfo, candidate)
      fail("Expected mismatched aggregate metadata")
    } catch (error: PdfSessionException) {
      assertEquals("pdf_mutation_failed", error.code)
    }
  }

  private fun coordinator() = MutableDocumentCoordinator(
    sourcePath = "working.pdf",
    generation = 1L,
    pages = listOf(
      PdfPageDimensions(100.0, 100.0),
      PdfPageDimensions(200.0, 200.0),
      PdfPageDimensions(300.0, 300.0),
    ),
    sessionWorker = PdfSessionWorker(),
    artifactPolicy = TestDocumentArtifactPolicy(),
  ).also { it.setActivePage(1) }
}
