package com.margelo.nitro.inksignpdf

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.graphics.lowlatency.CanvasFrontBufferedRenderer
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.ArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class LowLatencyInkDrawCallbackTest : LowLatencyInkPresenterTestBase() {
  @Test
  fun finalSnapshotDrawsOverlappingContoursAsIndependentFills() {
    val token = LowLatencyInkRenderToken(generation = 30L, sequence = 2L)
    val snapshot = LowLatencyInkFinalSnapshot(
      generation = token.generation,
      sequence = token.sequence,
      paths = overlappingOppositePathData(),
      pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
      color = Color.BLACK,
      bufferWidth = 50,
      bufferHeight = 50,
    )
    val callback = LowLatencyInkDrawCallback(
      currentGeneration = AtomicLong(token.generation),
      lastConsumedSequence = AtomicLong(0L),
      payloads = LowLatencyInkPayloadMailbox(),
      finalSnapshotFor = { candidate -> if (candidate == token) snapshot else null },
    )
    val bitmap = Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888)
    try {
      Canvas(bitmap).drawColor(Color.WHITE)
      callback.installFinalSnapshot(token)
      callback.onDrawMultiBufferedLayer(Canvas(bitmap), 50, 50, listOf(token))
      assertEquals(Color.BLACK, bitmap.getPixel(20, 20))
      assertEquals(1L, callback.diagnostics().finalMultiBufferSnapshotDrawCount)
    } finally { bitmap.recycle() }
  }

  @Test
  fun finalCommitIgnoresRetainedIncrementalTokensAndDrawsInstalledSnapshotOnce() {
    val token = LowLatencyInkRenderToken(generation = 9L, sequence = 4L)
    val snapshot = LowLatencyInkFinalSnapshot(
      generation = token.generation,
      sequence = token.sequence,
      paths = listOf(InkPathData.fromCommands(listOf(
        InkPathCommand(InkPathCommand.MOVE, 10f, 10f),
        InkPathCommand(InkPathCommand.LINE, 30f, 10f),
        InkPathCommand(InkPathCommand.LINE, 20f, 30f),
        InkPathCommand(InkPathCommand.CLOSE),
      ))),
      pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
      color = Color.BLACK,
      bufferWidth = 100,
      bufferHeight = 100,
    )
    val callback = LowLatencyInkDrawCallback(
      currentGeneration = AtomicLong(token.generation),
      lastConsumedSequence = AtomicLong(0L),
      payloads = LowLatencyInkPayloadMailbox(),
      finalSnapshotFor = { candidate -> if (candidate == token) snapshot else null },
    )
    val renderer = FakeRenderer(valid = true)
    val canvas = Canvas(Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888))

    callback.installFinalSnapshot(token)
    callback.onDrawMultiBufferedLayer(
      canvas,
      100,
      100,
      listOf(
        LowLatencyInkRenderToken(9L, 1L),
        LowLatencyInkRenderToken(9L, 2L),
        token,
      ),
    )
    renderer.commit()

    assertEquals(1, renderer.commitCount)
    assertEquals(1L, callback.diagnostics().finalMultiBufferSnapshotDrawCount)
  }

  @Test
  fun diagnosticsReadsRemainNonBlockingWhileWorkerPublishesCleanupSnapshot() {
    val created = ArrayList<FakeRenderer>()
    val callbackEntered = CountDownLatch(1)
    val releaseCallback = CountDownLatch(1)
    val blockOnce = AtomicReference(true)
    val presenter = presenter(
      created,
      beforeDiagnosticsPublish = {
        if (blockOnce.compareAndSet(true, false)) {
          callbackEntered.countDown()
          assertTrue(releaseCallback.await(5, TimeUnit.SECONDS))
        }
      },
    )
    val token = LowLatencyInkRenderToken(12L, 1L)
    val snapshot = LowLatencyInkFinalSnapshot(
      generation = token.generation,
      sequence = token.sequence,
      paths = listOf(InkPathData(
        commands = listOf(
          InkPathCommand(InkPathCommand.MOVE, 1f, 1f),
          InkPathCommand(InkPathCommand.LINE, 2f, 1f),
          InkPathCommand(InkPathCommand.LINE, 1f, 2f),
          InkPathCommand(InkPathCommand.CLOSE),
        ),
        bounds = InkBounds(1f, 1f, 2f, 2f),
      )),
      pageToView = PageTransform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0),
      color = Color.BLACK,
      bufferWidth = 300,
      bufferHeight = 300,
    )

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      presenter.resetActive(token.generation)
      assertTrue(presenter.requestDraw(drawRequest(1L, generation = token.generation)))
      created.single().commitOnWorkerThread = true
      assertTrue(presenter.handoff(token.generation, token.sequence, snapshot))
    }

    assertTrue(callbackEntered.await(5, TimeUnit.SECONDS))
    repeat(20) {
      instrumentation.runOnMainSync {
        assertTrue(presenter.drawDiagnostics() != null)
      }
    }
    releaseCallback.countDown()
    created.single().awaitCommitCallback()
    instrumentation.runOnMainSync {
      presenter.clear()
      val diagnostics = requireNotNull(presenter.drawDiagnostics())
      assertEquals(0, diagnostics.workerPathCacheCount)
      assertFalse(diagnostics.workerStableBitmapPresent)
      assertFalse(diagnostics.workerOffscreenPresent)
      presenter.release()
    }
  }

  @Test
  fun callbackDiagnosticsDistinguishDrawingAndStaleCallbacks() {
    val callback = AtomicReference<CanvasFrontBufferedRenderer.Callback<LowLatencyInkRenderToken>>()
    val fakeRenderer = FakeRenderer(true)
    val presenter = LowLatencyInkPresenter(
      instrumentation.targetContext,
      LowLatencyInkRendererFactory { _, drawCallback ->
        callback.set(drawCallback)
        fakeRenderer
      },
      surfaceValidity = { true },
    )

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      presenter.resetActive(3L)
      assertTrue(presenter.requestDraw(drawRequest(sequence = 1L, generation = 3L)))
      val token = fakeRenderer.requests.removeFirst()
      val canvas = Canvas(Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888))
      callback.get().onDrawFrontBufferedLayer(canvas, 300, 300, token)
      presenter.resetActive(4L)
      callback.get().onDrawFrontBufferedLayer(canvas, 300, 300, token)
      val diagnostics = presenter.drawDiagnostics()
      requireNotNull(diagnostics)
      assertEquals(2L, diagnostics.callbackCount)
      assertEquals(1L, diagnostics.drawingCallbackCount)
      assertEquals(1L, diagnostics.staleCallbackCount)
      assertEquals(1L, diagnostics.renderedRegionCount)
      presenter.release()
    }
  }

  @Test
  fun supersededCallbackIsNoOpAndLatestSelfSufficientPayloadDraws() {
    val callback = AtomicReference<CanvasFrontBufferedRenderer.Callback<LowLatencyInkRenderToken>>()
    val fakeRenderer = FakeRenderer(true)
    val presenter = LowLatencyInkPresenter(
      instrumentation.targetContext,
      LowLatencyInkRendererFactory { _, drawCallback ->
        callback.set(drawCallback)
        fakeRenderer
      },
      surfaceValidity = { true },
    )

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      presenter.resetActive(1L)
      assertTrue(presenter.requestDraw(rectDrawRequest(1L, 10, 10, 20, 20)))
      assertTrue(presenter.requestDraw(rectDrawRequest(2L, 10, 10, 110, 110)))
      assertEquals(2, fakeRenderer.requests.size)

      val bitmap = Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888)
      val canvas = Canvas(bitmap)
      callback.get().onDrawFrontBufferedLayer(canvas, 300, 300, fakeRenderer.requests.removeFirst())
      callback.get().onDrawFrontBufferedLayer(canvas, 300, 300, fakeRenderer.requests.removeFirst())

      val diagnostics = requireNotNull(presenter.drawDiagnostics())
      assertEquals(1L, diagnostics.drawingCallbackCount)
      assertEquals(1L, diagnostics.renderedRegionCount)
      assertEquals(1L, diagnostics.staleCallbackCount)
      assertEquals(1L, presenter.diagnostics().payloads.resolvedPayloadCount)
      assertEquals(1L, presenter.diagnostics().payloads.supersededPayloadCount)
      assertEquals(0, presenter.diagnostics().payloads.pendingPayloadCount)
      presenter.release()
    }
  }

  @Test
  fun submissionFailureReleasesPayloadAndEndsSubmissionTrace() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created)

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      created.single().throwOnRender = true
      presenter.resetActive(1L)

      try {
        presenter.requestDraw(drawRequest(sequence = 1L, generation = 1L))
        throw AssertionError("Expected renderer submission to fail")
      } catch (_: IllegalStateException) {
        assertEquals(0, presenter.diagnostics().payloads.pendingPayloadCount)
        assertEquals(0, presenter.diagnostics().payloads.executingPayloadCount)
      }
      presenter.release()
    }
  }

  @Test
  fun selfSufficientUnionMatchesSequentialDisjointRegionDrawing() {
    val first = rectDrawRequest(1L, 10, 10, 30, 30)
    val second = rectDrawRequest(2L, 100, 100, 120, 120)
    val replacement = multiRectDrawRequest(
      sequence = 2L,
      dirtyRegion = first.dirtyRegion.union(second.dirtyRegion),
      paths = first.paths + second.paths,
    )

    val sequentialMailbox = LowLatencyInkPayloadMailbox()
    val sequentialCallback = LowLatencyInkDrawCallback(
      AtomicLong(1L), AtomicLong(0L), sequentialMailbox,
    )
    val sequentialBitmap = Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888)
    val sequentialCanvas = Canvas(sequentialBitmap)
    val firstToken = sequentialMailbox.publish(first)
    sequentialCallback.onDrawFrontBufferedLayer(sequentialCanvas, 300, 300, firstToken)
    val secondToken = sequentialMailbox.publish(second)
    sequentialCallback.onDrawFrontBufferedLayer(sequentialCanvas, 300, 300, secondToken)

    val coalescedMailbox = LowLatencyInkPayloadMailbox()
    val coalescedCallback = LowLatencyInkDrawCallback(
      AtomicLong(1L), AtomicLong(0L), coalescedMailbox,
    )
    val coalescedBitmap = Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888)
    val coalescedCanvas = Canvas(coalescedBitmap)
    val supersededToken = coalescedMailbox.publish(first)
    val replacementToken = coalescedMailbox.publish(replacement)
    coalescedCallback.onDrawFrontBufferedLayer(
      coalescedCanvas, 300, 300, supersededToken,
    )
    coalescedCallback.onDrawFrontBufferedLayer(
      coalescedCanvas, 300, 300, replacementToken,
    )

    assertTrue(sequentialBitmap.sameAs(coalescedBitmap))
    assertEquals(1L, coalescedMailbox.diagnostics().supersededPayloadCount)
  }

  @Test
  fun acknowledgedStablePixelsSurviveALaterCrossingTailReplacement() {
    val stablePath = rectDrawRequest(1L, 20, 95, 220, 105).paths.single().copy(
      key = "stable-real/0-1",
      stable = true,
      stableContourStart = 0L,
      stableContourEnd = 1L,
    )
    val oldTailPath = rectDrawRequest(1L, 90, 50, 100, 150).paths.single().copy(
      key = "real/1-2",
    )
    val firstRequest = multiRectDrawRequest(
      sequence = 1L,
      dirtyRegion = InkDirtyRegion(19, 49, 221, 151),
      paths = listOf(stablePath, oldTailPath),
    ).copy(stableBoundary = 1L)

    val mailbox = LowLatencyInkPayloadMailbox()
    val callback = LowLatencyInkDrawCallback(
      AtomicLong(1L), AtomicLong(0L), mailbox,
    )
    val bitmap = Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val firstToken = mailbox.publish(firstRequest)
    callback.onDrawFrontBufferedLayer(canvas, 300, 300, firstToken)
    callback.completeFrontBufferedLayerForTest()

    // The acknowledged stable path is intentionally absent, matching UI rolling-prefix
    // eviction. The dirty box crosses it while replacing the old mutable tail.
    val newTailPath = rectDrawRequest(2L, 110, 50, 120, 150).paths.single().copy(
      key = "real/2-3",
    )
    val replacement = multiRectDrawRequest(
      sequence = 2L,
      dirtyRegion = InkDirtyRegion(89, 49, 121, 151),
      paths = listOf(newTailPath),
    ).copy(stableBoundary = 1L)
    val replacementToken = mailbox.publish(replacement)
    callback.onDrawFrontBufferedLayer(canvas, 300, 300, replacementToken)

    assertEquals(Color.CYAN, bitmap.getPixel(105, 100))
    assertEquals(Color.TRANSPARENT, bitmap.getPixel(95, 70))
    assertEquals(Color.CYAN, bitmap.getPixel(115, 70))
  }

  @Test
  fun stablePixelsAreBakedOnceAcrossCallbacksBeforeUiAcknowledgement() {
    val stablePath = rectDrawRequest(1L, 20, 95, 220, 105).paths.single().copy(
      key = "stable-real/0-1",
      stable = true,
      stableContourStart = 0L,
      stableContourEnd = 1L,
    )
    val firstRequest = multiRectDrawRequest(
      sequence = 1L,
      dirtyRegion = InkDirtyRegion(19, 94, 221, 106),
      paths = listOf(stablePath),
    ).copy(stableBoundary = 1L)
    val secondRequest = firstRequest.copy(sequence = 2L)

    val mailbox = LowLatencyInkPayloadMailbox()
    val callback = LowLatencyInkDrawCallback(
      AtomicLong(1L), AtomicLong(0L), mailbox,
    )
    val bitmap = Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)

    callback.onDrawFrontBufferedLayer(canvas, 300, 300, mailbox.publish(firstRequest))
    val afterFirstCallback = bitmap.copy(Bitmap.Config.ARGB_8888, false)
    // No front-buffer completion is delivered between these worker callbacks, so the second
    // request must not bake the same antialiased stable geometry into stableBitmap again.
    callback.onDrawFrontBufferedLayer(canvas, 300, 300, mailbox.publish(secondRequest))

    assertTrue(afterFirstCallback.sameAs(bitmap))
  }

  @Test
  fun callbackFailureReleasesExecutingPayload() {
    val mailbox = LowLatencyInkPayloadMailbox()
    val callback = LowLatencyInkDrawCallback(
      AtomicLong(1L),
      AtomicLong(0L),
      mailbox,
    )
    val token = mailbox.publish(drawRequest(sequence = 1L, generation = 1L))
    val canvas = Canvas(Bitmap.createBitmap(300, 300, Bitmap.Config.ARGB_8888))

    try {
      callback.onDrawFrontBufferedLayer(canvas, 301, 300, token)
      throw AssertionError("Expected callback buffer validation to fail")
    } catch (_: IllegalArgumentException) {
      assertEquals(0, mailbox.diagnostics().executingPayloadCount)
      assertEquals(0, mailbox.diagnostics().pendingPayloadCount)
    }
  }
}
