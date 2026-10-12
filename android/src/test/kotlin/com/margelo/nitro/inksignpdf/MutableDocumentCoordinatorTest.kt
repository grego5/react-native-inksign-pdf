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
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class MutableDocumentCoordinatorTest {
  @Test
  fun pageInfoTracksCommittedInkOnTheExplicitPage() {
    val empty = MutableDocumentCoordinator(
      sessionWorker = PdfSessionWorker(),
      artifactPolicy = TestDocumentArtifactPolicy(),
    )
    assertFalse(empty.hasDocument)

    val coordinator = coordinator()
    assertFalse(coordinator.pageInfo(1).hasInk)
    val ink = StrokeOutline.fromCommands(listOf(
      InkPathCommand(InkPathCommand.MOVE, 0f, 0f),
      InkPathCommand(InkPathCommand.CUBIC, 10f, 0f, 3f, 4f, 7f, -4f),
      InkPathCommand(InkPathCommand.CLOSE),
    ))
    val page = coordinator.page(1)
    page.history.append(ink)
    assertTrue(coordinator.pageInfo(1).hasInk)

    assertFalse(coordinator.pageInfo(0).hasInk)
    assertTrue(coordinator.pageInfo(1).hasInk)

    coordinator.undoHistory(page)
    assertFalse(coordinator.pageInfo(1).hasInk)
    coordinator.redoHistory(page)
    assertTrue(coordinator.pageInfo(1).hasInk)
    coordinator.clearHistory(page)
    assertFalse(coordinator.pageInfo(1).hasInk)
  }

  @Test
  fun pageIdsRemainStableAcrossMoveAndRemovalCandidate() {
    val coordinator = coordinator()
    val original = coordinator.pages.map { it.id }

    val viewer = ViewerDocumentState(coordinator)
    viewer.activatePage(1)
    val moved = coordinator.movePageCandidate(viewer.activePageIndex, 0)
    assertEquals(original[1], moved.pages[0].id)
    assertEquals(original[0], moved.pages[1].id)
    coordinator.installCandidate("moved.pdf", moved.pages)
    viewer.pagesPublished()
    assertEquals(original[1], viewer.activePageId())

    val removed = coordinator.removePageCandidate(viewer.activePageIndex)
    assertEquals(listOf(original[0], original[2]), removed.pages.map { it.id })
    coordinator.installCandidate("removed.pdf", removed.pages)
    viewer.pagesPublished()
    assertEquals(original[0], viewer.activePageId())
  }

  @Test
  fun viewerSelectsCurrentAndAddedPageIdentitiesAfterPublication() {
    val coordinator = coordinator()
    val existingPages = coordinator.pages.toList()
    val dimensions = listOf(
      PdfPageDimensions(400.0, 500.0),
      PdfPageDimensions(600.0, 700.0),
    )
    val viewers = AddPagesActivePage.entries.associateWith {
      ViewerDocumentState(coordinator).apply { activatePage(1) }
    }
    val current = coordinator.appendCandidate(dimensions)

    assertEquals(existingPages.map { it.id }, coordinator.pages.map { it.id })
    assertEquals(5, current.pages.size)
    assertTrue(existingPages.indices.all { current.pages[it] === existingPages[it] })
    assertTrue(!coordinator.structuralDirty)
    coordinator.installCandidate("appended.pdf", current.pages)
    viewers.forEach { (selection, viewer) -> viewer.pagesPublished(selection) }
    assertEquals(existingPages[1].id, viewers.getValue(AddPagesActivePage.CURRENT).activePageId())
    assertEquals(current.pages[3].id, viewers.getValue(AddPagesActivePage.FIRSTADDED).activePageId())
    assertEquals(current.pages[4].id, viewers.getValue(AddPagesActivePage.LASTADDED).activePageId())
  }

  @Test
  fun publicationMarksStructuralDirtyWithoutChangingPageHistory() {
    val coordinator = coordinator()
    val histories = coordinator.pages.associate { it.id to it.history }
    val candidate = coordinator.movePageCandidate(1, 0)
    coordinator.installCandidate("working.pdf", candidate.pages)

    assertTrue(coordinator.structuralDirty)
    assertEquals(candidate.pages.map { it.id }, coordinator.pages.map { it.id })
    coordinator.pages.forEach { page -> assertTrue(histories[page.id] === page.history) }
  }

  @Test
  fun removingANeighborRetainsEverySurvivingPageHistory() {
    val coordinator = coordinator()
    val retained = coordinator.pages[0]
    val trailing = coordinator.pages[2]

    val candidate = coordinator.removePageCandidate(1)
    coordinator.installCandidate("candidate.pdf", candidate.pages)

    assertTrue(coordinator.pages[0] === retained)
    assertTrue(coordinator.pages[1] === trailing)
  }

  @Test
  fun committedRotationAdvancesOnlyTargetGeometryRevisionAndRetainsHistory() {
    val coordinator = coordinator()
    val target = coordinator.page(1)
    val neighboringPage = coordinator.page(0)
    val outline = StrokeOutline.fromCommands(listOf(
      InkPathCommand(InkPathCommand.MOVE, 10f, 20f),
      InkPathCommand(InkPathCommand.LINE, 30f, 40f),
    ))
    target.history.append(outline)
    target.history.undoMutation()
    val expectedHistoryState = target.history.state()

    val candidate = coordinator.rotatePageCandidate(
      target.id,
      PdfPageDimensions(200.0, 100.0, rotation = 1),
    )

    assertEquals("Candidate preparation must not mutate published geometry", 0L, target.geometryRevision)
    assertEquals(0L, neighboringPage.geometryRevision)
    assertEquals(target.id, candidate.pages[1].id)
    assertEquals(1L, candidate.pages[1].geometryRevision)
    assertTrue(candidate.pages[1].history === target.history)
    assertEquals(expectedHistoryState, candidate.pages[1].history.state())

    coordinator.installCandidate("rotated.pdf", candidate.pages)

    assertEquals(1L, coordinator.pageForId(target.id)?.geometryRevision)
    assertEquals(0L, coordinator.pageForId(neighboringPage.id)?.geometryRevision)
    assertTrue(coordinator.pageForId(target.id)?.history === target.history)
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
      coordinator.removePageCandidate(0)
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
    assertEquals(coordinator.pages.map { it.id }, snapshot.pages.map { it.id })
    assertEquals(coordinator.sourcePath, snapshot.sourcePath)
  }

  @Test
  fun aggregateValidationRejectsPageOrderThatDoesNotMatchPdfiumMetadata() {
    val coordinator = coordinator()
    val candidate = coordinator.movePageCandidate(1, 0)
    val unchangedInfo = coordinator.sessionInfo()

    try {
      coordinator.validateCandidateAggregate(unchangedInfo, candidate)
      fail("Expected mismatched aggregate metadata")
    } catch (error: PdfSessionException) {
      assertEquals("pdf_mutation_failed", error.code)
    }
  }

  @Test
  fun failedReplacementPreparationAndCommitLeaveDocumentEmpty() = runBlocking {
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
      openCandidate(
        coordinator,
        sourcePath = sourceA.absolutePath,
        fallbackFont = null,
      )
      val committedPath = coordinator.sourcePath
      val committedGeneration = coordinator.generation
      var replacementNotified = false
      val preparationFailure = runCatching {
        openCandidate(
          coordinator,
          sourcePath = sourceB.absolutePath,
          fallbackFont = null,
          notifyPublished = {
            replacementNotified = true
          },
        )
      }
      assertTrue(preparationFailure.isFailure)
      assertFalse(replacementNotified)
      assertFalse(coordinator.hasDocument)
      assertEquals("", coordinator.sourcePath)
      assertTrue(coordinator.generation > committedGeneration)
      assertTrue(opened[0].closed)
      assertFalse(File(committedPath).exists())

      val commitFailure = runCatching {
        openCandidate(
          coordinator,
          sourcePath = sourceC.absolutePath,
          fallbackFont = null,
          awaitPrepared = { info ->
            worker.reserveOpenAttemptId(info.generation)
          },
          notifyPublished = {
            replacementNotified = true
          },
        )
      }
      assertTrue(commitFailure.isFailure)
      assertFalse(replacementNotified)
      assertFalse(coordinator.hasDocument)
      assertEquals("", coordinator.sourcePath)
      assertTrue(coordinator.generation > committedGeneration)
      assertTrue(opened[0].closed)
      assertTrue(opened.last().closed)
      assertFalse(File(committedPath).exists())
      assertTrue(coordinator.workingFiles().isEmpty())
      assertTrue(artifactPolicy.allocatedWorkingFiles.last().let { !it.exists() })

      worker.updateTileEpoch(committedGeneration, 1L)
      val completed = CountDownLatch(1)
      val rendered = AtomicReference<Result<List<PdfTile>>>()
      worker.renderTiles(committedGeneration, 1L, emptyList()) {
        rendered.set(it)
        completed.countDown()
      }
      assertTrue(completed.await(5L, TimeUnit.SECONDS))
      assertTrue(rendered.get().isFailure)
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
        openCandidate(
          coordinator,
          sourcePath = invalidSource.absolutePath,
          fallbackFont = null,
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
  fun replacementClearsImmediatelyAndRetiresOldReaderBeforeReadiness() = runBlocking {
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
      openCandidate(
        coordinator,
        sourcePath = sourceA.absolutePath,
        fallbackFont = null,
      )
      val oldPath = coordinator.sourcePath
      val oldGeneration = coordinator.generation
      val replacement = async(Dispatchers.IO) {
        openCandidate(
          coordinator,
          sourcePath = sourceB.absolutePath,
          fallbackFont = null,
          awaitPrepared = { _ ->
            readinessEntered.complete(Unit)
            releaseReadiness.await()
            publicationEvents += "prepare"
            publicationEvents += "handoff"
          },
          notifyPublished = {
            publicationEvents += "install"
            replacementNotified = true
            publicationEvents += "notify"
          },
        )
      }
      readinessEntered.await()
      assertEquals("", coordinator.sourcePath)
      assertTrue(coordinator.generation > oldGeneration)
      assertFalse(File(oldPath).exists())
      assertTrue(opened[0].closed)
      assertTrue(publicationEvents.isEmpty())
      worker.updateTileEpoch(oldGeneration, 1L)
      val oldReaderRender = CompletableDeferred<Result<List<PdfTile>>>()
      worker.renderTiles(oldGeneration, 1L, emptyList()) { result ->
        oldReaderRender.complete(result)
      }
      assertTrue(oldReaderRender.await().isFailure)
      assertEquals(0, opened[0].renderCount)

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
  fun cancellingOneWorkerWaiterDoesNotInvalidateOtherRequestsInItsSession() = runBlocking {
    val source = File.createTempFile("cancel-waiter-session-", ".pdf").apply { writeText("source") }
    val assemblyEntered = CountDownLatch(1)
    val releaseAssembly = CountDownLatch(1)
    val worker = PdfSessionWorker(
      opener = PdfSessionOpener { path, generation ->
        OpenTestSession(path, generation, listOf(PdfPageDimensions(100.0, 100.0)))
      },
      assembler = { _, _, scratch ->
        assemblyEntered.countDown()
        if (!releaseAssembly.await(5, TimeUnit.SECONDS)) error("test assembly was not released")
        scratch.writeText("prepared candidate")
        listOf(PdfPageDimensions(100.0, 100.0))
      },
    )
    val coordinator = MutableDocumentCoordinator(
      sessionWorker = worker,
      artifactPolicy = TestDocumentArtifactPolicy(),
    )

    try {
      openCandidate(
        coordinator,
        sourcePath = source.absolutePath,
        fallbackFont = null,
      )
      val generation = coordinator.generation
      val operationID = coordinator.beginOperation()
      val mutation = async(Dispatchers.IO) {
        coordinator.executeStructuralMutation(
          generation = generation,
          request = PdfiumAssemblyRequest(
            operation = PdfiumAssemblyOperation.MOVE,
            pageIndex = 0,
            destinationIndex = 0,
          ),
          candidateBuilder = { coordinator.movePageCandidate(1, 0) },
          notifyPublished = { error("unexpected publication") },
        )
      }
      assertTrue(assemblyEntered.await(5, TimeUnit.SECONDS))
      mutation.cancel()
      mutation.join()
      coordinator.endOperation(operationID)

      val render = CompletableDeferred<Result<List<PdfTile>>>()
      worker.updateTileEpoch(generation, 1L)
      worker.renderTiles(generation, 1L, emptyList()) { render.complete(it) }
      releaseAssembly.countDown()
      assertTrue(render.await().isSuccess)
    } finally {
      releaseAssembly.countDown()
      coordinator.dispose()
      worker.close()
      source.delete()
    }
  }

  @Test
  fun newestOpenSupersedesRequestsDuringHandoff() = runBlocking {
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
    try {
      val openA = async(Dispatchers.IO) {
        runCatching {
          openCandidate(
            coordinator,
            sourcePath = sourceA.absolutePath,
            fallbackFont = null,
            awaitPrepared = { _ ->
              handoffEntered.countDown()
              check(releaseHandoff.await(5L, TimeUnit.SECONDS))
            },
          )
        }
      }
      assertTrue(handoffEntered.await(5L, TimeUnit.SECONDS))

      val openB = async(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
        runCatching {
          openCandidate(
            coordinator,
            sourcePath = sourceB.absolutePath,
            fallbackFont = null,
          )
        }
      }
      val openC = async(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
        openCandidate(
          coordinator,
          sourcePath = sourceC.absolutePath,
          fallbackFont = null,
        )
      }
      assertEquals(3, artifactPolicy.allocatedWorkingFiles.size)

      releaseHandoff.countDown()
      assertTrue(openA.await().isFailure)
      assertTrue(openB.await().isFailure)
      assertEquals(300.0, openC.await().pages.single().width, 0.0)
      assertEquals(3, artifactPolicy.allocatedWorkingFiles.size)
      assertTrue("A" in openedContents)
      assertTrue("C" in openedContents)
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
  fun failedReplacementLeavesEmptyAndNewestLaterOpenPublishes() = runBlocking {
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
    val fontA = PdfFallbackFont("a.ttf", byteArrayOf(1), 0.0)
    val fontB = PdfFallbackFont("b.ttf", byteArrayOf(2), 0.0)
    val fontC = PdfFallbackFont("c.ttf", byteArrayOf(3), 0.0)
    val fontD = PdfFallbackFont("d.ttf", byteArrayOf(4), 0.0)
    suspend fun open(
      path: File,
      font: PdfFallbackFont,
      prepare: (PdfSessionInfo) -> Unit = {},
      awaitReady: suspend () -> Unit = {},
      sourcePath: String = path.absolutePath,
    ) =
      openCandidate(
        coordinator,
        sourcePath = sourcePath,
        fallbackFont = AndroidFallbackFont(font.source, font.collectionIndex),
        resolveFallbackFont = { font },
        awaitPrepared = { info ->
          awaitReady()
          prepare(info)
        },
      )

    assertTrue(!coordinator.hasDocument)
    val openedA = open(sourceA, fontA, sourcePath = sourceA.toURI().toString())
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
    assertEquals("", coordinator.sourcePath)
    assertTrue(coordinator.generation > committedAGeneration)

    val failedC = runCatching {
      open(sourceC, fontC, prepare = {
        throw PdfSessionException("pdf_load_failed", "candidate preparation failed")
      })
    }
    assertTrue(failedC.isFailure)
    assertFalse(coordinator.hasDocument)
    assertEquals("", coordinator.sourcePath)
    assertEquals(null, coordinator.fallbackFont)
    assertFalse(File(committedAPath).exists())
    assertTrue(opened.single { it.info.pages.single().width == 100.0 }.closed)

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
    coordinator.closeDocument()
    assertEquals(null, coordinator.fallbackFont)
    worker.close()
    sourceA.delete()
    sourceB.delete()
    sourceC.delete()
    sourceD.delete()
    Unit
  }

  /** Test client of the document-only prepare/commit boundary. */
  private suspend fun openCandidate(
    coordinator: MutableDocumentCoordinator,
    sourcePath: String,
    fallbackFont: AndroidFallbackFont?,
    resolveFallbackFont: suspend (AndroidFallbackFont) -> PdfFallbackFont = { error("No test font resolver") },
    awaitPrepared: suspend (PdfSessionInfo) -> Unit = {},
    notifyPublished: (PdfSessionInfo) -> Unit = {},
  ): PdfSessionInfo {
    val pending = coordinator.prepareOpen(fallbackFont, resolveFallbackFont,
      prepareSource = { destination ->
        withContext(Dispatchers.IO) {
          val source = if (sourcePath.startsWith("file:")) File(java.net.URI(sourcePath)) else File(sourcePath)
          source.copyTo(destination, overwrite = true)
        }
      })
    try {
      coordinator.awaitOpen(pending) { awaitPrepared(pending.info) }
      return coordinator.commitOpen(pending, notifyPublished)
    } finally { coordinator.finishOpen(pending) }
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
  )
}
