package com.margelo.nitro.inksignpdf

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
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
    assertEquals(4, candidate.pages.size)
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

  @Test
  fun installationFailureDiscardsCandidateBeforeWorkerCommit() = runBlocking {
    val sourceA = File.createTempFile("open-install-a-", ".pdf").apply { writeText("A") }
    val sourceB = File.createTempFile("open-install-b-", ".pdf").apply { writeText("B") }
    val opened = mutableListOf<OpenTestSession>()
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      OpenTestSession(path, generation, listOf(PdfPageDimensions(100.0, 100.0)))
        .also(opened::add)
    })
    val coordinator = MutableDocumentCoordinator(
      sessionWorker = worker,
      artifactPolicy = TestDocumentArtifactPolicy(),
    )
    try {
      coordinator.executeOpen(
        sourcePath = sourceA.absolutePath,
        fallbackFont = null,
        preparePresentation = { it },
        installPresentation = { it },
      )
      val committedPath = coordinator.sourcePath
      val committedGeneration = coordinator.generation
      val committedPages = coordinator.pages.map { it.id }
      var restored = false
      val failure = runCatching {
        coordinator.executeOpen(
          sourcePath = sourceB.absolutePath,
          fallbackFont = null,
          preparePresentation = { it },
          installPresentation = { throw IllegalStateException("presentation failed") },
          restorePresentation = { restored = true },
        )
      }
      assertTrue(failure.isFailure)
      assertTrue(restored)
      assertEquals(committedPath, coordinator.sourcePath)
      assertEquals(committedGeneration, coordinator.generation)
      assertEquals(committedPages, coordinator.pages.map { it.id })
      assertTrue(File(committedPath).exists())
      assertTrue(!opened[0].closed)
      worker.updateTileEpoch(committedGeneration, 1L)
      val completed = CountDownLatch(1)
      val rendered = AtomicReference<Result<List<PdfTile>>>()
      worker.renderTiles(committedGeneration, 1L, emptyList()) {
        rendered.set(it)
        completed.countDown()
      }
      assertTrue(completed.await(5L, TimeUnit.SECONDS))
      assertTrue(rendered.get().isSuccess)
    } finally {
      worker.close()
      sourceA.delete()
      sourceB.delete()
    }
    Unit
  }

  @Test
  fun openBCFailsAndDCommitsBeforeBFinishes() = runBlocking {
    val sourceA = File.createTempFile("open-a-", ".pdf").apply { writeText("A") }
    val sourceB = File.createTempFile("open-b-", ".pdf").apply { writeText("B") }
    val sourceC = File.createTempFile("open-c-", ".pdf").apply { writeText("C") }
    val sourceD = File.createTempFile("open-d-", ".pdf").apply { writeText("D") }
    val opened = mutableListOf<OpenTestSession>()
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      val contents = File(path).readText()
      val pageSize = when (contents) {
        "A" -> 100.0
        "B" -> 200.0
        "C" -> 300.0
        else -> 400.0
      }
      val pages = listOf(PdfPageDimensions(pageSize, pageSize))
      OpenTestSession(path, generation, pages).also(opened::add)
    })
    val coordinator = MutableDocumentCoordinator(
      sourcePath = "",
      generation = 0L,
      pages = emptyList(),
      sessionWorker = worker,
      artifactPolicy = TestDocumentArtifactPolicy(),
    )
    val fontA = PdfFallbackFont("a.ttf", null)
    val fontB = PdfFallbackFont("b.ttf", null)
    val fontC = PdfFallbackFont("c.ttf", null)
    val fontD = PdfFallbackFont("d.ttf", null)
    suspend fun open(path: File, font: PdfFallbackFont, prepare: (PdfSessionInfo) -> Unit = {}) =
      coordinator.executeOpen(
        sourcePath = path.absolutePath,
        fallbackFont = font,
        preparePresentation = { info -> prepare(info); info },
        installPresentation = { it },
      )

    assertTrue(!coordinator.hasDocument)
    val openedA = open(sourceA, fontA)
    assertEquals(1, openedA.pageCount)
    val committedAPath = coordinator.sourcePath
    val committedAGeneration = coordinator.generation
    assertEquals(fontA, coordinator.fallbackFont)
    assertEquals("A", File(committedAPath).readText())

    val replacementPresented = CountDownLatch(1)
    val releaseReplacement = CountDownLatch(1)
    var committedDPath = ""
    var committedDGeneration = 0L
    val openB = async(Dispatchers.IO) {
      runCatching {
        open(sourceB, fontB) { info ->
          assertEquals(200.0, info.pages.single().width, 0.0)
            replacementPresented.countDown()
            check(releaseReplacement.await(5L, TimeUnit.SECONDS))
        }
      }
    }
    assertTrue(replacementPresented.await(5L, TimeUnit.SECONDS))

    try {
      val failedC = runCatching {
        open(sourceC, fontC) {
          throw PdfSessionException("presentation_rejected", "candidate presentation failed")
        }
      }
      assertTrue(failedC.isFailure)
      assertEquals(committedAPath, coordinator.sourcePath)
      assertEquals(committedAGeneration, coordinator.generation)
      assertEquals(fontA, coordinator.fallbackFont)
      assertEquals("A", File(coordinator.sourcePath).readText())

      val openedD = open(sourceD, fontD)
      assertEquals(400.0, openedD.pages.single().width, 0.0)
      committedDPath = coordinator.sourcePath
      committedDGeneration = coordinator.generation
      assertTrue(committedDGeneration > committedAGeneration)
      assertEquals(fontD, coordinator.fallbackFont)
      assertEquals("D", File(committedDPath).readText())
      assertTrue("A's working file retires after D commits", !File(committedAPath).exists())

      worker.updateTileEpoch(committedDGeneration, 1L)
      val renderCompleted = CountDownLatch(1)
      val rendered = AtomicReference<Result<List<PdfTile>>>()
      worker.renderTiles(committedDGeneration, 1L, emptyList()) {
        rendered.set(it)
        renderCompleted.countDown()
      }
      assertTrue(renderCompleted.await(5L, TimeUnit.SECONDS))
      assertTrue(rendered.get().isSuccess)
    } finally {
      releaseReplacement.countDown()
    }

    assertTrue(openB.await().isFailure)
    assertEquals(committedDPath, coordinator.sourcePath)
    assertEquals(committedDGeneration, coordinator.generation)
    assertEquals(fontD, coordinator.fallbackFont)
    assertEquals("D", File(coordinator.sourcePath).readText())
    assertTrue(opened.first { it.info.sourcePath == committedDPath }.renderCount >= 1)
    worker.close()
    sourceA.delete()
    sourceB.delete()
    sourceC.delete()
    sourceD.delete()
    Unit
  }

  private class OpenTestSession(
    path: String,
    generation: Long,
    pages: List<PdfPageDimensions>,
  ) : PdfSessionResource {
    override val info = PdfSessionInfo(path, pages, generation)
    @Volatile var closed = false
      private set
    @Volatile var renderCount = 0
      private set
    override fun renderTiles(requests: List<PdfTileRequest>, beforeEach: () -> Unit): List<PdfTile> {
      renderCount += 1
      requests.forEach { beforeEach() }
      return emptyList()
    }
    override fun renderPreview(request: PdfTileRequest, beforeRender: () -> Unit): PdfTile =
      error("Rendering is outside this test")
    override fun close() { closed = true }
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
