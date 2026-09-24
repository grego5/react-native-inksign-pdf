package com.margelo.nitro.inksignpdf

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PdfSessionWorkerTest {
  @Test
  fun failedOpenCandidateLeavesCommittedSessionRenderableAndAttemptIdsAreNeverReused() {
    val opened = mutableListOf<FakeSession>()
    val opener = object : PdfSessionOpener {
      override fun open(path: String, generation: Long): PdfSessionResource {
        if (path == "invalid.pdf") throw PdfSessionException("pdf_load_failed", "invalid PDF")
        return FakeSession(path, generation).also(opened::add)
      }
    }
    val worker = PdfSessionWorker(opener = opener)
    try {
      val committedId = openAndCommit(worker, "working.pdf", afterGeneration = 0L).generation

      val replacement = CountDownLatch(1)
      val failedAttempt = worker.reserveOpenAttemptId(committedId)
      worker.prepareOpen(failedAttempt, "invalid.pdf", null) { result ->
        assertTrue(result.isFailure)
        replacement.countDown()
      }
      assertTrue(replacement.await(5L, TimeUnit.SECONDS))
      val discarded = CountDownLatch(1)
      worker.discardPreparedOpen(failedAttempt) { result ->
        assertTrue(result.isSuccess)
        discarded.countDown()
      }
      assertTrue(discarded.await(5L, TimeUnit.SECONDS))
      assertFalse(opened.single().closed)
      assertTrue(worker.reserveOpenAttemptId(committedId) > failedAttempt)

      worker.updateTileEpoch(committedId, 1L)
      val rendered = CountDownLatch(1)
      val renderResult = AtomicReference<Result<List<PdfTile>>>()
      worker.renderTiles(committedId, 1L, listOf(testTileRequest(pageIndex = 0))) {
        renderResult.set(it)
        rendered.countDown()
      }
      assertTrue(rendered.await(5L, TimeUnit.SECONDS))
      assertTrue(renderResult.get().isSuccess)
    } finally {
      worker.close()
    }
  }

  @Test
  fun discardingReadyOpenCandidateKeepsCommittedSessionRenderable() {
    val opened = mutableListOf<FakeSession>()
    val opener = object : PdfSessionOpener {
      override fun open(path: String, generation: Long): PdfSessionResource =
        FakeSession(path, generation).also(opened::add)
    }
    val worker = PdfSessionWorker(opener = opener)
    try {
      val committedId = openAndCommit(worker, "working.pdf", afterGeneration = 0L).generation

      val replacement = CountDownLatch(1)
      val candidateId = worker.reserveOpenAttemptId(committedId)
      worker.prepareOpen(candidateId, "candidate.pdf", null) {
        assertTrue(it.isSuccess)
        replacement.countDown()
      }
      assertTrue(replacement.await(5L, TimeUnit.SECONDS))
      assertFalse(opened[0].closed)
      assertFalse(opened[1].closed)

      val discarded = CountDownLatch(1)
      worker.discardPreparedOpen(candidateId) { assertTrue(it.isSuccess); discarded.countDown() }
      assertTrue(discarded.await(5L, TimeUnit.SECONDS))
      assertFalse(opened[0].closed)
      assertTrue(opened[1].closed)

      worker.updateTileEpoch(committedId, 1L)
      val rendered = CountDownLatch(1)
      val renderResult = AtomicReference<Result<List<PdfTile>>>()
      worker.renderTiles(committedId, 1L, listOf(testTileRequest(pageIndex = 0))) {
        renderResult.set(it)
        rendered.countDown()
      }
      assertTrue(rendered.await(5L, TimeUnit.SECONDS))
      assertTrue(renderResult.get().isSuccess)
    } finally {
      worker.close()
    }
  }

  @Test
  fun preparedMutationDoesNotReplaceCurrentSessionUntilCommit() {
    val opened = mutableListOf<FakeSession>()
    val opener = object : PdfSessionOpener {
      override fun open(path: String, generation: Long): PdfSessionResource {
        return FakeSession(path, generation).also { opened += it }
      }
    }
    val scratch = File.createTempFile("prepared-mutation-", ".pdf")
    val worker = PdfSessionWorker(
      opener = opener,
      assembler = { _, _, output ->
        output.writeText("candidate")
        listOf(PdfPageDimensions(300.0, 300.0))
      },
    )
    try {
      val initialInfo = openAndCommit(worker, "working.pdf", afterGeneration = 0L)

      val prepared = CountDownLatch(1)
      worker.prepareMutation(
        "working.pdf",
        scratch.path,
        initialInfo.generation,
        PdfiumAssemblyRequest(PdfiumAssemblyOperation.REMOVE, pageIndex = 0),
        null,
        { it.delete() },
      ) { result ->
        assertTrue(result.isSuccess)
        prepared.countDown()
      }
      assertTrue(prepared.await(5L, TimeUnit.SECONDS))
      assertFalse(opened[0].closed)
      assertFalse(opened[1].closed)

      val committed = CountDownLatch(1)
      worker.commitPreparedMutation(scratch.path, initialInfo.generation) { result ->
        assertTrue(result.isSuccess)
        committed.countDown()
      }
      assertTrue(committed.await(5L, TimeUnit.SECONDS))
      assertTrue(opened[0].closed)
      assertFalse(opened[1].closed)
    } finally {
      worker.close()
      scratch.delete()
    }
  }

  @Test
  fun discardedPreparedMutationRetainsCurrentSessionAndRetiresCandidate() {
    val opened = mutableListOf<FakeSession>()
    val opener = object : PdfSessionOpener {
      override fun open(path: String, generation: Long): PdfSessionResource {
        return FakeSession(path, generation).also { opened += it }
      }
    }
    val scratch = File.createTempFile("discarded-mutation-", ".pdf")
    val retired = CountDownLatch(1)
    val worker = PdfSessionWorker(
      opener = opener,
      assembler = { _, _, output ->
        output.writeText("candidate")
        listOf(PdfPageDimensions(300.0, 300.0))
      },
    )
    try {
      val initialInfo = openAndCommit(worker, "working.pdf", afterGeneration = 0L)
      val prepared = CountDownLatch(1)
      worker.prepareMutation(
        "working.pdf",
        scratch.path,
        initialInfo.generation,
        PdfiumAssemblyRequest(PdfiumAssemblyOperation.MOVE, pageIndex = 0, destinationIndex = 0),
        null,
        { it.delete() },
      ) { prepared.countDown() }
      assertTrue(prepared.await(5L, TimeUnit.SECONDS))

      worker.discardPreparedMutation(scratch.path) {
        it.delete()
        retired.countDown()
      }
      assertTrue(retired.await(5L, TimeUnit.SECONDS))
      assertFalse(opened[0].closed)
      assertTrue(opened[1].closed)
      assertFalse(scratch.exists())
    } finally {
      worker.close()
      scratch.delete()
    }
  }

  @Test
  fun multiPageFakeSessionReportsOrderedDimensions() {
    val pages = listOf(
      PdfPageDimensions(300.0, 400.0),
      PdfPageDimensions(600.0, 800.0),
    )
    val opener = RecordingSessionOpener(pages = pages)
    val worker = PdfSessionWorker(opener = opener)
    try {
      val info = openAndCommit(worker, "multi-page.pdf", afterGeneration = 6L)
      assertEquals(pages, info.pages)
      assertEquals(2, info.pageCount)
    } finally {
      worker.close()
    }
  }

  @Test
  fun stalePreviewEpochIsRejectedBeforePdfAllocation() {
    val opener = RecordingSessionOpener()
    val worker = PdfSessionWorker(opener = opener)
    try {
      val info = openAndCommit(worker, "preview.pdf", afterGeneration = 0L)

      worker.updatePreviewEpoch(generation = info.generation, previewEpoch = 2L)
      val result = AtomicReference<Result<PdfTile>>()
      val completed = CountDownLatch(1)
      worker.renderPreview(
        generation = info.generation,
        previewEpoch = 1L,
        request = testTileRequest(pageIndex = 0),
      ) {
        result.set(it)
        completed.countDown()
      }

      assertTrue(completed.await(5L, TimeUnit.SECONDS))
      assertEquals("operation_cancelled", (result.get().exceptionOrNull() as PdfSessionException).code)
      assertEquals(0, opener.resource.get().previewRenderCount)
    } finally {
      worker.close()
    }
  }

  @Test
  fun staleGenerationCannotPublishTilesFromThePreviousSession() {
    val opener = RecordingSessionOpener()
    val worker = PdfSessionWorker(opener = opener)
    try {
      val oldInfo = openAndCommit(worker, "old.pdf", afterGeneration = 0L)

      val replacement = CountDownLatch(1)
      val newAttemptId = worker.reserveOpenAttemptId(oldInfo.generation)
      worker.prepareOpen(newAttemptId, "new.pdf", null) { result ->
        assertTrue(result.isSuccess)
        replacement.countDown()
      }
      assertTrue(replacement.await(5L, TimeUnit.SECONDS))

      val oldRender = render(worker, oldInfo.generation, 1L)
      assertTrue(oldRender.isSuccess)
      val newCommitted = CountDownLatch(1)
      assertTrue(worker.commitPreparedOpen(newAttemptId) {
        assertTrue(it.isSuccess)
        newCommitted.countDown()
      })
      assertTrue(newCommitted.await(5L, TimeUnit.SECONDS))

      val staleResult = render(worker, oldInfo.generation, 2L)
      assertEquals(
        "operation_cancelled",
        (staleResult.exceptionOrNull() as PdfSessionException).code,
      )
    } finally {
      worker.close()
    }
  }

  @Test
  fun mixedPageTileBatchIsRejected() {
    val info = PdfSessionInfo(
      sourcePath = "multi-page.pdf",
      pages = listOf(
        PdfPageDimensions(300.0, 400.0),
        PdfPageDimensions(600.0, 800.0),
      ),
      generation = 7L,
    )
    val requests = listOf(
      testTileRequest(pageIndex = 0),
      testTileRequest(pageIndex = 1),
    )

    try {
      validatePdfTileBatch(info, requests)
      fail("expected mixed-page tile batch to be rejected")
    } catch (error: PdfSessionException) {
      assertEquals("invalid_tile_request", error.code)
    }
  }

  @Test
  fun supersededOpenClosesCandidateAndRejectsOperation() {
    val opener = BlockingSessionOpener()
    val worker = PdfSessionWorker(opener = opener)
    try {
      val oldAttemptId = worker.reserveOpenAttemptId(afterGeneration = 0L)
      val oldResult = AtomicReference<Result<PdfSessionInfo>>()
      val oldCompleted = CountDownLatch(1)
      worker.prepareOpen(oldAttemptId, "old.pdf", null) {
        oldResult.set(it)
        oldCompleted.countDown()
      }
      assertTrue(opener.oldOpenStarted.await(5L, TimeUnit.SECONDS))

      val latestAttemptId = worker.reserveOpenAttemptId(afterGeneration = 0L)
      val newResult = AtomicReference<Result<PdfSessionInfo>>()
      val newCompleted = CountDownLatch(1)
      worker.prepareOpen(latestAttemptId, "new.pdf", null) {
        newResult.set(it)
        newCompleted.countDown()
      }
      opener.releaseOld.countDown()

      assertTrue(oldCompleted.await(5L, TimeUnit.SECONDS))
      assertTrue(newCompleted.await(5L, TimeUnit.SECONDS))

      val oldError = oldResult.get().exceptionOrNull() as PdfSessionException
      assertEquals("operation_cancelled", oldError.code)
      assertTrue(opener.oldResource.get().closed)
      assertEquals("new.pdf", newResult.get().getOrThrow().sourcePath)
      val committed = CountDownLatch(1)
      assertTrue(worker.commitPreparedOpen(latestAttemptId) {
        assertTrue(it.isSuccess)
        committed.countDown()
      })
      assertTrue(committed.await(5L, TimeUnit.SECONDS))
      assertTrue(render(worker, latestAttemptId, 1L).isSuccess)
    } finally {
      worker.close()
    }
  }

  @Test
  fun closeInvalidatesInFlightOpenAndClosesCandidate() {
    val opener = BlockingSessionOpener()
    val worker = PdfSessionWorker(opener = opener)
    try {
      val result = AtomicReference<Result<PdfSessionInfo>>()
      val completed = CountDownLatch(1)
      val attemptId = worker.reserveOpenAttemptId(afterGeneration = 0L)
      worker.prepareOpen(attemptId, "old.pdf", null) {
        result.set(it)
        completed.countDown()
      }

      assertTrue(opener.oldOpenStarted.await(5L, TimeUnit.SECONDS))
      worker.close()
      opener.releaseOld.countDown()

      assertTrue(completed.await(5L, TimeUnit.SECONDS))
      val error = result.get().exceptionOrNull() as PdfSessionException
      assertEquals("operation_cancelled", error.code)
      assertTrue(opener.oldResource.get().closed)
    } finally {
      worker.close()
    }
  }

  @Test
  fun replacementLeavesCallerSourcesUntouched() {
    val sourceA = File.createTempFile("inksignpdf-source-", ".pdf")
    val sourceB = File.createTempFile("inksignpdf-source-", ".pdf")
    val opener = RecordingSessionOpener()
    val worker = PdfSessionWorker(opener = opener)
    try {
      val initial = openAndCommit(worker, sourceA.absolutePath, afterGeneration = 0L)
      val replacementId = worker.reserveOpenAttemptId(initial.generation)
      val replacement = prepare(worker, replacementId, sourceB.absolutePath)
      assertEquals(sourceB.absolutePath, replacement.sourcePath)
      val committed = CountDownLatch(1)
      assertTrue(worker.commitPreparedOpen(replacementId) {
        assertTrue(it.isSuccess)
        committed.countDown()
      })
      assertTrue(committed.await(5L, TimeUnit.SECONDS))
      assertTrue(sourceA.exists())
      assertTrue(sourceB.exists())
      worker.close()
      assertTrue(sourceA.exists())
      assertTrue(sourceB.exists())
    } finally {
      worker.close()
      sourceA.delete()
      sourceB.delete()
    }
  }

  @Test
  fun disposalClosesReaderWithoutDeletingCallerSource() {
    val source = File.createTempFile("inksignpdf-source-", ".pdf")
    var sourceExistedWhenClosed = false
    val opener = RecordingSessionOpener(onClose = {
      sourceExistedWhenClosed = source.exists()
    })
    val worker = PdfSessionWorker(opener = opener)
    try {
      openAndCommit(worker, "current.pdf", afterGeneration = 0L)

      worker.close()
      assertTrue(opener.resource.get().closedSignal.await(5L, TimeUnit.SECONDS))
      assertTrue(sourceExistedWhenClosed)
      assertTrue(source.exists())
    } finally {
      worker.close()
      source.delete()
    }
  }

  @Test
  fun closeReleasesTheCurrentSessionOnTheWorker() {
    val opener = RecordingSessionOpener()
    val worker = PdfSessionWorker(opener = opener)
    try {
      openAndCommit(worker, "current.pdf", afterGeneration = 0L)

      worker.close()

      assertTrue(opener.resource.get().closedSignal.await(5L, TimeUnit.SECONDS))
      assertTrue(opener.resource.get().closed)
    } finally {
      worker.close()
    }
  }

  private fun openAndCommit(
    worker: PdfSessionWorker,
    path: String,
    afterGeneration: Long,
    fallbackFont: PdfFallbackFont? = null,
  ): PdfSessionInfo {
    val attemptId = worker.reserveOpenAttemptId(afterGeneration)
    val info = prepare(worker, attemptId, path, fallbackFont)
    val committed = CountDownLatch(1)
    assertTrue(worker.commitPreparedOpen(attemptId) { result ->
      assertTrue(result.isSuccess)
      committed.countDown()
    })
    assertTrue(committed.await(5L, TimeUnit.SECONDS))
    return info
  }

  private fun prepare(
    worker: PdfSessionWorker,
    attemptId: Long,
    path: String,
    fallbackFont: PdfFallbackFont? = null,
  ): PdfSessionInfo {
    val result = AtomicReference<Result<PdfSessionInfo>>()
    val completed = CountDownLatch(1)
    worker.prepareOpen(attemptId, path, fallbackFont) {
      result.set(it)
      completed.countDown()
    }
    assertTrue(completed.await(5L, TimeUnit.SECONDS))
    return result.get().getOrThrow()
  }

  private fun render(worker: PdfSessionWorker, generation: Long, tileEpoch: Long): Result<List<PdfTile>> {
    worker.updateTileEpoch(generation, tileEpoch)
    val result = AtomicReference<Result<List<PdfTile>>>()
    val completed = CountDownLatch(1)
    worker.renderTiles(generation, tileEpoch, listOf(testTileRequest(pageIndex = 0))) {
      result.set(it)
      completed.countDown()
    }
    assertTrue(completed.await(5L, TimeUnit.SECONDS))
    return result.get()
  }

  private class BlockingSessionOpener : PdfSessionOpener {
    val oldOpenStarted = CountDownLatch(1)
    val releaseOld = CountDownLatch(1)
    val oldResource = AtomicReference<FakeSession>()

    override fun open(path: String, generation: Long): PdfSessionResource {
      if (path == "old.pdf") {
        oldOpenStarted.countDown()
        check(releaseOld.await(5L, TimeUnit.SECONDS))
      }
      val resource = FakeSession(path, generation)
      if (path == "old.pdf") oldResource.set(resource)
      return resource
    }
  }

  private class RecordingSessionOpener(
    private val onClose: (() -> Unit)? = null,
    private val pages: List<PdfPageDimensions> =
      listOf(PdfPageDimensions(300.0, 300.0)),
  ) : PdfSessionOpener {
    val resource = AtomicReference<FakeSession>()

    override fun open(path: String, generation: Long): PdfSessionResource {
      return FakeSession(path, generation, onClose, pages).also(resource::set)
    }
  }

  private class FakeSession(
    sourcePath: String,
    generation: Long,
    private val onClose: (() -> Unit)? = null,
    pages: List<PdfPageDimensions> = listOf(PdfPageDimensions(300.0, 300.0)),
  ) : PdfSessionResource {
    override val info = PdfSessionInfo(
      sourcePath = sourcePath,
      pages = pages,
      generation = generation,
    )
    @Volatile
    var closed = false
      private set
    val closedSignal = CountDownLatch(1)
    @Volatile
    var previewRenderCount = 0
      private set

    override fun renderTiles(
      requests: List<PdfTileRequest>,
      beforeEach: () -> Unit,
    ): List<PdfTile> {
      requests.forEach { beforeEach() }
      return emptyList()
    }

    override fun renderPreview(
      request: PdfTileRequest,
      beforeRender: () -> Unit,
    ): PdfTile {
      previewRenderCount += 1
      beforeRender()
      throw UnsupportedOperationException("preview is not used by this fake")
    }

    override fun close() {
      onClose?.invoke()
      closed = true
      closedSignal.countDown()
    }
  }

  private fun testTileRequest(pageIndex: Int): PdfTileRequest {
    return PdfTileRequest(
      key = PdfTileKey(
        generation = 7L,
        pageSwitchId = 1L,
        pageIndex = pageIndex,
        level = 0,
        x = 0,
        y = 0,
      ),
      leftPx = 0,
      topPx = 0,
      widthPx = 1,
      heightPx = 1,
      scale = 1.0,
    )
  }
}
