package com.margelo.nitro.inksignpdf

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
  fun failedReplacementPreparationAndCommitPreservePublishedDocument() = runBlocking {
    val sourceA = File.createTempFile("open-install-a-", ".pdf").apply { writeText("A") }
    val sourceB = File.createTempFile("open-install-b-", ".pdf").apply { writeText("invalid") }
    val sourceC = File.createTempFile("open-install-c-", ".pdf").apply { writeText("C") }
    val opened = mutableListOf<OpenTestSession>()
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      if (File(path).readText() == "invalid") {
        throw PdfSessionException("pdf_load_failed", "invalid candidate")
      }
      OpenTestSession(path, generation, listOf(PdfPageDimensions(100.0, 100.0)))
        .also(opened::add)
    })
    val artifactPolicy = TestDocumentArtifactPolicy()
    val coordinator = MutableDocumentCoordinator(
      sessionWorker = worker,
      artifactPolicy = artifactPolicy,
    )
    try {
      coordinator.executeOpen(
        sourcePath = sourceA.absolutePath,
        fallbackFont = null,
        awaitContainerSize = { ViewportSize(300.0, 200.0, 1.0) },
        preparePresentation = { info, _ -> info },
        publishPresentation = { it },
      )
      val committedPath = coordinator.sourcePath
      val committedGeneration = coordinator.generation
      var replacementNotified = false
      val preparationFailure = runCatching {
        coordinator.executeOpen(
          sourcePath = sourceB.absolutePath,
          fallbackFont = null,
          awaitContainerSize = { ViewportSize(300.0, 200.0, 1.0) },
          preparePresentation = { info, _ -> info },
          publishPresentation = { it },
          notifyPublished = { replacementNotified = true },
        )
      }
      assertTrue(preparationFailure.isFailure)
      assertFalse(replacementNotified)
      assertTrue(coordinator.hasDocument)
      assertEquals(committedPath, coordinator.sourcePath)
      assertEquals(committedGeneration, coordinator.generation)
      assertFalse(opened[0].closed)
      assertTrue(File(committedPath).exists())

      var handoffAborted = false
      val commitFailure = runCatching {
        coordinator.executeOpen(
          sourcePath = sourceC.absolutePath,
          fallbackFont = null,
          awaitContainerSize = { ViewportSize(300.0, 200.0, 1.0) },
          preparePresentation = { info, _ ->
            worker.reserveOpenAttemptId(info.generation)
            info
          },
          beginHandoff = {},
          publishPresentation = { it },
          notifyPublished = { replacementNotified = true },
          abortHandoff = { handoffAborted = true },
        )
      }
      assertTrue(commitFailure.isFailure)
      assertTrue(handoffAborted)
      assertFalse(replacementNotified)
      assertTrue(coordinator.hasDocument)
      assertEquals(committedPath, coordinator.sourcePath)
      assertEquals(committedGeneration, coordinator.generation)
      assertFalse(opened[0].closed)
      assertTrue(opened.last().closed)
      assertTrue(File(committedPath).exists())
      assertEquals(setOf(File(committedPath)), coordinator.workingFiles())
      assertTrue(artifactPolicy.allocatedWorkingFiles.last().let { !it.exists() })

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
      sourceC.delete()
    }
    Unit
  }

  @Test
  fun initialOpenFailureLeavesDocumentEmpty() = runBlocking {
    val invalidSource = File.createTempFile("open-initial-invalid-", ".pdf").apply {
      writeText("invalid")
    }
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, _ ->
      if (File(path).readText() == "invalid") {
        throw PdfSessionException("pdf_load_failed", "invalid candidate")
      }
      error("Unexpected valid candidate")
    })
    val artifactPolicy = TestDocumentArtifactPolicy()
    val coordinator = MutableDocumentCoordinator(
      sessionWorker = worker,
      artifactPolicy = artifactPolicy,
    )
    try {
      val failure = runCatching {
        coordinator.executeOpen(
          sourcePath = invalidSource.absolutePath,
          fallbackFont = null,
          awaitContainerSize = { ViewportSize(300.0, 200.0, 1.0) },
          preparePresentation = { info, _ -> info },
          publishPresentation = { it },
        )
      }

      assertTrue(failure.isFailure)
      assertFalse(coordinator.hasDocument)
      assertEquals("", coordinator.sourcePath)
      assertTrue(coordinator.pages.isEmpty())
      assertTrue(coordinator.workingFiles().isEmpty())
      assertFalse(artifactPolicy.allocatedWorkingFiles.single().exists())
    } finally {
      worker.close()
      invalidSource.delete()
    }
    Unit
  }

  @Test
  fun replacementPublishesAndReleasesOldReaderOnlyAfterReadiness() = runBlocking {
    val sourceA = File.createTempFile("open-ready-a-", ".pdf").apply { writeText("A") }
    val sourceB = File.createTempFile("open-ready-b-", ".pdf").apply { writeText("B") }
    val opened = mutableListOf<OpenTestSession>()
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      OpenTestSession(path, generation, listOf(PdfPageDimensions(100.0, 100.0)))
        .also(opened::add)
    })
    val coordinator = MutableDocumentCoordinator(
      sessionWorker = worker,
      artifactPolicy = TestDocumentArtifactPolicy(),
    )
    val readinessEntered = CompletableDeferred<Unit>()
    val releaseReadiness = CompletableDeferred<Unit>()
    var replacementNotified = false
    val publicationEvents = mutableListOf<String>()
    try {
      coordinator.executeOpen(
        sourcePath = sourceA.absolutePath,
        fallbackFont = null,
        awaitContainerSize = { ViewportSize(300.0, 200.0, 1.0) },
        preparePresentation = { info, _ -> info },
        publishPresentation = { it },
      )
      val oldPath = coordinator.sourcePath
      val oldGeneration = coordinator.generation
      val replacement = async(Dispatchers.IO) {
        coordinator.executeOpen(
          sourcePath = sourceB.absolutePath,
          fallbackFont = null,
          awaitContainerSize = {
            readinessEntered.complete(Unit)
            releaseReadiness.await()
            ViewportSize(300.0, 200.0, 1.0)
          },
          preparePresentation = { info, size ->
            assertEquals(300.0, size.widthPx, 0.0)
            publicationEvents += "prepare"
            info
          },
          beginHandoff = { publicationEvents += "handoff" },
          publishPresentation = { publicationEvents += "install"; it },
          notifyPublished = {
            replacementNotified = true
            publicationEvents += "notify"
          },
        )
      }
      readinessEntered.await()
      assertEquals(oldPath, coordinator.sourcePath)
      assertEquals(oldGeneration, coordinator.generation)
      assertTrue(File(oldPath).exists())
      assertFalse(opened[0].closed)
      assertTrue(publicationEvents.isEmpty())
      worker.updateTileEpoch(oldGeneration, 1L)
      val oldReaderRender = CompletableDeferred<Result<List<PdfTile>>>()
      worker.renderTiles(oldGeneration, 1L, emptyList()) { result ->
        oldReaderRender.complete(result)
      }
      assertTrue(oldReaderRender.await().isSuccess)
      assertEquals(1, opened[0].renderCount)

      releaseReadiness.complete(Unit)
      assertEquals(100.0, replacement.await().pages.single().width, 0.0)
      assertTrue(coordinator.sourcePath != oldPath)
      assertTrue(coordinator.generation > oldGeneration)
      assertTrue(replacementNotified)
      assertFalse(File(oldPath).exists())
      assertTrue(opened[0].closed)
      assertEquals(listOf("prepare", "handoff", "install", "notify"), publicationEvents)
    } finally {
      releaseReadiness.complete(Unit)
      worker.close()
      sourceA.delete()
      sourceB.delete()
    }
    Unit
  }

  @Test
  fun newestOpenQueuedDuringHandoffWinsWithoutAllocatingOlderCandidate() = runBlocking {
    val sourceA = File.createTempFile("open-queued-a-", ".pdf").apply { writeText("A") }
    val sourceB = File.createTempFile("open-queued-b-", ".pdf").apply { writeText("B") }
    val sourceC = File.createTempFile("open-queued-c-", ".pdf").apply { writeText("C") }
    val opened = mutableListOf<OpenTestSession>()
    val openedContents = mutableListOf<String>()
    val worker = PdfSessionWorker(opener = PdfSessionOpener { path, generation ->
      val contents = File(path).readText()
      openedContents += contents
      val width = when (contents) {
        "A" -> 100.0
        "B" -> 200.0
        else -> 300.0
      }
      OpenTestSession(path, generation, listOf(PdfPageDimensions(width, width)))
        .also(opened::add)
    })
    val artifactPolicy = TestDocumentArtifactPolicy()
    val coordinator = MutableDocumentCoordinator(
      sessionWorker = worker,
      artifactPolicy = artifactPolicy,
    )
    val handoffEntered = CountDownLatch(1)
    val releaseHandoff = CountDownLatch(1)
    val viewportSize = { ViewportSize(300.0, 200.0, 1.0) }
    try {
      val openA = async(Dispatchers.IO) {
        coordinator.executeOpen(
          sourcePath = sourceA.absolutePath,
          fallbackFont = null,
          awaitContainerSize = viewportSize,
          preparePresentation = { info, _ -> info },
          beginHandoff = {
            handoffEntered.countDown()
            check(releaseHandoff.await(5L, TimeUnit.SECONDS))
          },
          publishPresentation = { it },
        )
      }
      assertTrue(handoffEntered.await(5L, TimeUnit.SECONDS))

      val openB = async(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
        runCatching {
          coordinator.executeOpen(
            sourcePath = sourceB.absolutePath,
            fallbackFont = null,
            awaitContainerSize = viewportSize,
            preparePresentation = { info, _ -> info },
            publishPresentation = { it },
          )
        }
      }
      val openC = async(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
        coordinator.executeOpen(
          sourcePath = sourceC.absolutePath,
          fallbackFont = null,
          awaitContainerSize = viewportSize,
          preparePresentation = { info, _ -> info },
          publishPresentation = { it },
        )
      }
      assertEquals(1, artifactPolicy.allocatedWorkingFiles.size)

      releaseHandoff.countDown()
      assertEquals(100.0, openA.await().pages.single().width, 0.0)
      assertTrue(openB.await().isFailure)
      assertEquals(300.0, openC.await().pages.single().width, 0.0)
      assertEquals(2, artifactPolicy.allocatedWorkingFiles.size)
      assertEquals(listOf("A", "C"), openedContents)
      assertEquals(File(coordinator.sourcePath), artifactPolicy.allocatedWorkingFiles.last())
    } finally {
      releaseHandoff.countDown()
      worker.close()
      sourceA.delete()
      sourceB.delete()
      sourceC.delete()
    }
    Unit
  }

  @Test
  fun waitingBIsSupersededByFailingCAndDThenPublishes() = runBlocking {
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
    val artifactPolicy = TestDocumentArtifactPolicy()
    val coordinator = MutableDocumentCoordinator(
      sourcePath = "",
      generation = 0L,
      pages = emptyList(),
      sessionWorker = worker,
      artifactPolicy = artifactPolicy,
    )
    val fontA = PdfFallbackFont("a.ttf", null)
    val fontB = PdfFallbackFont("b.ttf", null)
    val fontC = PdfFallbackFont("c.ttf", null)
    val fontD = PdfFallbackFont("d.ttf", null)
    suspend fun open(
      path: File,
      font: PdfFallbackFont,
      prepare: (PdfSessionInfo) -> Unit = {},
      awaitReady: suspend () -> Unit = {},
    ) =
      coordinator.executeOpen(
        sourcePath = path.absolutePath,
        fallbackFont = font,
        preparePresentation = { info, _ -> prepare(info); info },
        publishPresentation = { it },
        awaitContainerSize = {
          awaitReady()
          ViewportSize(300.0, 200.0, 1.0)
        },
      )

    assertTrue(!coordinator.hasDocument)
    val openedA = open(sourceA, fontA)
    assertEquals(1, openedA.pageCount)
    val committedAPath = coordinator.sourcePath
    val committedAGeneration = coordinator.generation
    assertEquals(fontA, coordinator.fallbackFont)
    assertEquals("A", File(committedAPath).readText())

    val replacementPresented = CompletableDeferred<Unit>()
    var committedDPath = ""
    var committedDGeneration = 0L
    val openB = async(Dispatchers.IO) {
      runCatching {
        open(sourceB, fontB, awaitReady = {
          replacementPresented.complete(Unit)
          CompletableDeferred<Unit>().await()
        })
      }
    }
    replacementPresented.await()
    assertEquals(committedAPath, coordinator.sourcePath)

    val failedC = runCatching {
      open(sourceC, fontC) {
        throw PdfSessionException("pdf_load_failed", "candidate preparation failed")
      }
    }
    assertTrue(failedC.isFailure)
    assertTrue(coordinator.hasDocument)
    assertEquals(committedAPath, coordinator.sourcePath)
    assertEquals(committedAGeneration, coordinator.generation)
    assertEquals(fontA, coordinator.fallbackFont)
    assertTrue(File(committedAPath).exists())
    assertFalse(opened.single { it.info.pages.single().width == 100.0 }.closed)

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

    assertTrue(openB.await().isFailure)
    assertEquals(committedDPath, coordinator.sourcePath)
    assertEquals(committedDGeneration, coordinator.generation)
    assertEquals(fontD, coordinator.fallbackFont)
    assertEquals("D", File(coordinator.sourcePath).readText())
    assertTrue(opened.first { it.info.sourcePath == committedDPath }.renderCount >= 1)
    assertTrue(opened.single { it.info.pages.single().width == 100.0 }.closed)
    assertTrue(opened.single { it.info.pages.single().width == 200.0 }.closed)
    assertTrue(opened.single { it.info.pages.single().width == 300.0 }.closed)
    assertFalse(opened.single { it.info.pages.single().width == 400.0 }.closed)
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
