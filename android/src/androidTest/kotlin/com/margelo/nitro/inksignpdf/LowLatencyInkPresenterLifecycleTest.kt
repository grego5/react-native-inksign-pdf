package com.margelo.nitro.inksignpdf

import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.ArrayList
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
internal class LowLatencyInkPresenterLifecycleTest : LowLatencyInkPresenterTestBase() {
  @Test
  fun rendererIsCreatedOnceAndRecreatedOnlyAfterReleaseCompletes() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created)

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertEquals(1, created.size)
      assertEquals(1, presenter.diagnostics().rendererCreateCount)
      assertEquals(1, presenter.diagnostics().rendererCreateSuccesses)
      assertTrue(presenter.diagnostics().overlayAttached)
      assertTrue(presenter.diagnostics().surfaceAvailable)
      assertTrue(presenter.diagnostics().rendererPresent)
      assertTrue(presenter.diagnostics().rendererValid)

      presenter.onOverlaySurfaceDestroyed(presenter.view)
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertEquals(1, created.size)

      created.single().completeRelease()
    }
    instrumentation.waitForIdleSync()

    instrumentation.runOnMainSync {
      assertEquals(2, created.size)
      presenter.resetActive(7L)
      assertFalse(presenter.requestDraw(drawRequest(1L, generation = 6L)))
      assertTrue(presenter.requestDraw(drawRequest(1L, generation = 7L)))
      assertEquals(1, created[1].requests.size)
      presenter.release()
      presenter.release()
      assertEquals(1, created[1].releaseCount)
      assertFalse(presenter.requestDraw(drawRequest(1L)))
      created[1].completeRelease()
    }
    instrumentation.waitForIdleSync()
    instrumentation.runOnMainSync {
      assertEquals(2, presenter.diagnostics().rendererReleaseCompletions)
      assertEquals(
        LowLatencyInkRejectionReason.LIFECYCLE_STATE,
        presenter.diagnostics().lastRejectionReason,
      )
    }
  }

  @Test
  fun lifecycleLossCallbacksNotifyOwnerForSurfaceAndOverlayLoss() {
    val surfaceDestroyedPresenter = presenter(ArrayList())
    val overlayDetachedPresenter = presenter(ArrayList())
    var surfaceDestroyedCancellations = 0
    var overlayDetachedCancellations = 0

    instrumentation.runOnMainSync {
      surfaceDestroyedPresenter.setLifecycleCancellationListener {
        surfaceDestroyedCancellations += 1
      }
      surfaceDestroyedPresenter.onOverlayAttached(surfaceDestroyedPresenter.view)
      surfaceDestroyedPresenter.onOverlaySizeChanged(surfaceDestroyedPresenter.view, 300, 300)
      surfaceDestroyedPresenter.onOverlaySurfaceCreated(surfaceDestroyedPresenter.view)
      surfaceDestroyedPresenter.onOverlaySurfaceDestroyed(surfaceDestroyedPresenter.view)

      overlayDetachedPresenter.setLifecycleCancellationListener {
        overlayDetachedCancellations += 1
      }
      overlayDetachedPresenter.onOverlayAttached(overlayDetachedPresenter.view)
      overlayDetachedPresenter.onOverlaySizeChanged(overlayDetachedPresenter.view, 300, 300)
      overlayDetachedPresenter.onOverlaySurfaceCreated(overlayDetachedPresenter.view)
      overlayDetachedPresenter.onOverlayDetached(overlayDetachedPresenter.view)

      assertEquals(1, surfaceDestroyedCancellations)
      assertEquals(1, overlayDetachedCancellations)
      surfaceDestroyedPresenter.release()
      overlayDetachedPresenter.release()
    }
  }

  @Test
  fun surfaceRecreationRestoresAttachedStateWhenReleaseCompletesFirst() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created)

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertEquals(1, created.size)

      presenter.onOverlaySurfaceDestroyed(presenter.view)
      created.single().completeRelease()
    }
    instrumentation.waitForIdleSync()

    instrumentation.runOnMainSync {
      assertEquals(1, created.size)
      assertFalse(presenter.diagnostics().rendererPresent)
      assertEquals(0, presenter.diagnostics().presenterState)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertEquals(2, created.size)
      assertTrue(presenter.diagnostics().overlayAttached)
      assertTrue(presenter.diagnostics().surfaceAvailable)
      assertTrue(presenter.diagnostics().rendererPresent)
      assertTrue(presenter.diagnostics().rendererValid)
      presenter.release()
      created[1].completeRelease()
    }
  }

  @Test
  fun rejectionDiagnosticsIdentifyRendererGenerationAndSequenceFailures() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created)

    instrumentation.runOnMainSync {
      assertFalse(presenter.requestDraw(drawRequest(1L)))
      assertEquals(
        LowLatencyInkRejectionReason.RENDERER_MISSING,
        presenter.diagnostics().lastRejectionReason,
      )
      assertEquals(1, presenter.diagnostics().rendererMissingRejections)

      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      created.single().valid = false
      assertFalse(presenter.requestDraw(drawRequest(1L)))
      assertEquals(
        LowLatencyInkRejectionReason.RENDERER_INVALID,
        presenter.diagnostics().lastRejectionReason,
      )

      created.single().valid = true
      presenter.resetActive(7L)
      assertFalse(presenter.requestDraw(drawRequest(1L, generation = 6L)))
      assertEquals(
        LowLatencyInkRejectionReason.GENERATION_MISMATCH,
        presenter.diagnostics().lastRejectionReason,
      )
      assertTrue(presenter.requestDraw(drawRequest(1L, generation = 7L)))
      assertEquals(
        LowLatencyInkRejectionReason.NONE,
        presenter.diagnostics().lastRejectionReason,
      )
      assertEquals(1, presenter.diagnostics().acceptedSubmissionCount)
      assertFalse(presenter.requestDraw(drawRequest(1L, generation = 7L)))
      assertEquals(
        LowLatencyInkRejectionReason.STALE_SEQUENCE,
        presenter.diagnostics().lastRejectionReason,
      )
      presenter.release()
    }
  }

  @Test
  fun rendererCreationReportsExactlyOneStableBlocker() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created, surfaceValid = false)

    instrumentation.runOnMainSync {
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.PRESENTER_NOT_ATTACHED,
        presenter.diagnostics().creationBlocker,
      )

      presenter.onOverlayAttached(presenter.view)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.SURFACE_UNAVAILABLE,
        presenter.diagnostics().creationBlocker,
      )

      presenter.onOverlaySurfaceCreated(presenter.view)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.SURFACE_UNAVAILABLE,
        presenter.diagnostics().creationBlocker,
      )

      val sizedPresenter = presenter(ArrayList(), surfaceValid = true)
      sizedPresenter.onOverlayAttached(sizedPresenter.view)
      sizedPresenter.onOverlaySurfaceCreated(sizedPresenter.view)
      sizedPresenter.onOverlaySizeChanged(sizedPresenter.view, 0, 300)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.WIDTH_ZERO,
        sizedPresenter.diagnostics().creationBlocker,
      )
      sizedPresenter.onOverlaySizeChanged(sizedPresenter.view, 300, 0)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.HEIGHT_ZERO,
        sizedPresenter.diagnostics().creationBlocker,
      )
      sizedPresenter.onOverlaySizeChanged(sizedPresenter.view, 300, 300)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.NONE,
        sizedPresenter.diagnostics().creationBlocker,
      )
      sizedPresenter.onOverlaySizeChanged(sizedPresenter.view, 300, 300)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.RENDERER_ALREADY_PRESENT,
        sizedPresenter.diagnostics().creationBlocker,
      )
      sizedPresenter.onOverlaySurfaceDestroyed(sizedPresenter.view)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.RELEASE_IN_PROGRESS,
        sizedPresenter.diagnostics().creationBlocker,
      )
      sizedPresenter.onOverlayAttached(sizedPresenter.view)
      assertEquals(
        LowLatencyInkRendererCreationBlocker.RELEASE_IN_PROGRESS,
        sizedPresenter.diagnostics().creationBlocker,
      )
      sizedPresenter.release()
      assertEquals(
        LowLatencyInkRendererCreationBlocker.DISPOSED,
        sizedPresenter.diagnostics().creationBlocker,
      )
      presenter.release()
    }
  }

  @Test
  fun smokeDrawsUsePreservedFrontBufferAndDoNotUseDurableLayer() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created)

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertTrue(presenter.requestDraw(drawRequest(1L, 10, 10, 20, 20)))
      assertTrue(presenter.requestDraw(drawRequest(2L, 10, 10, 110, 110)))
      assertEquals(2, created.single().requests.size)
      assertEquals(0, created.single().clearCount)
      presenter.clear()
      presenter.clear()
      assertEquals(1, created.single().clearCount)
      assertEquals(2, created.single().cancelCount)
    }
  }

  @Test
  fun acceptedPresentationIsClearedOnceAcrossRepeatedCancellation() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created)

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertTrue(presenter.requestDraw(drawRequest(1L)))
      presenter.clear()
      presenter.clear()
      assertEquals(1, created.single().clearCount)
      presenter.release()
    }
  }

  @Test
  fun unavailableRendererDoesNotClaimRetainedPixels() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created, rendererValid = false)

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertFalse(presenter.requestDraw(drawRequest(1L)))
      presenter.clear()
      presenter.clear()
      assertEquals(0, created.single().clearCount)
      assertEquals(0, presenter.diagnostics().resetCount)
      presenter.release()
    }
  }

  @Test
  fun initiallyInvalidRendererIsRetainedUntilItBecomesValid() {
    val created = ArrayList<FakeRenderer>()
    val presenter = presenter(created, rendererValid = false)

    instrumentation.runOnMainSync {
      presenter.onOverlayAttached(presenter.view)
      presenter.onOverlaySizeChanged(presenter.view, 300, 300)
      presenter.onOverlaySurfaceCreated(presenter.view)
      assertEquals(1, presenter.diagnostics().invalidRendererCreations)
      assertTrue(presenter.diagnostics().rendererPresent)
      assertFalse(presenter.requestDraw(drawRequest(1L)))
      created.single().valid = true
      presenter.resetActive(4L)
      assertTrue(presenter.requestDraw(drawRequest(1L, generation = 4L)))
      assertEquals(1, presenter.diagnostics().rendererCreateSuccesses)
      presenter.release()
    }
  }

  @Test
  fun overlayIsTransparentAndNonInteractive() {
    val listener = NoOpOverlayListener()
    val view = AtomicReference<LowLatencyInkView>()
    instrumentation.runOnMainSync {
      view.set(LowLatencyInkView(instrumentation.targetContext, listener))
    }

    val overlay = view.get()
    assertFalse(overlay.isClickable)
    assertFalse(overlay.isFocusable)
    assertFalse(overlay.isFocusableInTouchMode)
    assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, overlay.importantForAccessibility)
  }
}
