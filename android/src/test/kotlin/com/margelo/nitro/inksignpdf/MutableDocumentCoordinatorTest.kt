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
    val candidate = coordinator.moveActiveCandidate(0)
    coordinator.installCandidate("working.pdf", candidate.pages, candidate.activePageId)

    assertTrue(coordinator.structuralDirty)
    assertEquals(candidate.activePageId, coordinator.pages[coordinator.activePageIndex].id)
  }

  @Test
  fun removeCandidateRejectsTheSolePage() {
    val coordinator = MutableDocumentCoordinator(
      sourcePath = "working.pdf",
      generation = 1L,
      pages = listOf(PdfPageDimensions(100.0, 100.0)),
    )
    try {
      coordinator.removeActiveCandidate()
      fail("Expected the last page to be required")
    } catch (error: IllegalStateException) {
      assertTrue(error.message.orEmpty().contains("retain one page"))
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
  ).also { it.setActivePage(1) }
}
