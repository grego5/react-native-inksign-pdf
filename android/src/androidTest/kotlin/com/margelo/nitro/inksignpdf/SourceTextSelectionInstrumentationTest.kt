package com.margelo.nitro.inksignpdf

import android.content.ClipboardManager
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.margelo.nitro.core.Promise
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real container routing and native menu tests; do not replace these with controller calls. */
@RunWith(AndroidJUnit4::class)
internal class SourceTextSelectionInstrumentationTest {
  private val instrumentation get() = InstrumentationRegistry.getInstrumentation()

  @Test fun longPressDragRetraceCopiesPathWithoutChangingDocumentOrAnnotationSelection() {
    withViewer { view, document, canvas, words ->
      val before = onMain { document.core.documentInfo() }
      var annotationEvents = 0
      onMain { view.onTextSelectionChange = { annotationEvents++ } }
      val baselineEvents = annotationEvents
      val b = point(canvas, words[1])
      val c = point(canvas, words[2])
      val a = point(canvas, words[0])
      touch(view, MotionEvent.ACTION_DOWN, b)
      touch(view, MotionEvent.ACTION_UP, b)
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
      touch(view, MotionEvent.ACTION_DOWN, b)
      awaitSelection(view, "B")
      touch(view, MotionEvent.ACTION_MOVE, c)
      assertEquals("B C", onMain { view.sourceSelection.selectedCopyText() })
      touch(view, MotionEvent.ACTION_MOVE, b)
      touch(view, MotionEvent.ACTION_MOVE, a)
      touch(view, MotionEvent.ACTION_UP, a)
      assertEquals("A B", onMain { view.sourceSelection.selectedCopyText() })
      clickCopy()
      assertEquals("A B", onMain {
        view.view.context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString()
      })
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
      assertEquals(before, onMain { document.core.documentInfo() })
      assertEquals(baselineEvents, annotationEvents)
      assertNotNull(onMain { view.getSelectedText().asSecondOrNull() })
    }
  }

  @Test fun fastSegmentIncludesCrossedWordsAndShortDragDoesNotSelect() {
    withViewer { view, _, canvas, words ->
      val a = point(canvas, words[0])
      val c = point(canvas, words[2])
      touch(view, MotionEvent.ACTION_DOWN, a)
      touch(view, MotionEvent.ACTION_MOVE, c)
      touch(view, MotionEvent.ACTION_UP, c)
      waitPastLongPress()
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
      touch(view, MotionEvent.ACTION_DOWN, a)
      awaitSelection(view, "A")
      touch(view, MotionEvent.ACTION_MOVE, c)
      touch(view, MotionEvent.ACTION_UP, c)
      assertEquals("A B C", onMain { view.sourceSelection.selectedCopyText() })
      val outside = ViewPoint(5.0, 5.0)
      touch(view, MotionEvent.ACTION_DOWN, outside)
      touch(view, MotionEvent.ACTION_UP, outside)
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
    }
  }

  @Test fun latePreparationAfterReleaseOrModeReplacementCannotInstallSelection() {
    withViewer { view, document, canvas, words ->
      val b = point(canvas, words[1])
      val gate = CompletableDeferred<Unit>()
      val entered = CountDownLatch(1)
      onMain { document.core.submit { entered.countDown(); gate.await() } }
      assertTrue(entered.await(5, TimeUnit.SECONDS))
      try {
        touch(view, MotionEvent.ACTION_DOWN, b)
        waitPastLongPress()
        touch(view, MotionEvent.ACTION_UP, b)
      } finally { gate.complete(Unit) }
      await { document.getPage(PageQuery.create(0.0)) }
      instrumentation.waitForIdleSync()
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
      touch(view, MotionEvent.ACTION_DOWN, b)
      awaitSelection(view, "B")
      onMain { view.setMode(InputMode.VIEW, null) }
      touch(view, MotionEvent.ACTION_MOVE, point(canvas, words[2]))
      touch(view, MotionEvent.ACTION_UP, b)
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
    }
  }

  @Test fun rotationAndDetachRetireHighlightsAndHeldStreams() {
    withViewer { view, document, canvas, words ->
      val b = point(canvas, words[1])
      touch(view, MotionEvent.ACTION_DOWN, b)
      awaitSelection(view, "B")
      await { document.rotatePage(0.0, 90.0) }
      touch(view, MotionEvent.ACTION_UP, b)
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
      onMain { view.document = null }
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
    }
  }

  @Test fun secondPointerHandsRemainingStreamToViewportAndNextPressStillWorks() {
    withViewer { view, _, canvas, words ->
      val b = point(canvas, words[1])
      touch(view, MotionEvent.ACTION_DOWN, b)
      awaitSelection(view, "B")
      val initialTransform = onMain { checkNotNull(canvas.textTransformSnapshot()).transform }
      val second = ViewPoint(b.x + 80.0, b.y + 80.0)
      twoPointers(view, MotionEvent.ACTION_POINTER_DOWN, b, second)
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
      for (step in 1..8) {
        twoPointers(view, MotionEvent.ACTION_MOVE, b,
          ViewPoint(second.x + step * 15.0, second.y + step * 15.0))
      }
      val zoomedTransform = onMain { checkNotNull(canvas.textTransformSnapshot()).transform }
      assertTrue("The existing viewport must zoom during the same held stream",
        checkNotNull(zoomedTransform.uniformScale()) > checkNotNull(initialTransform.uniformScale()) * 1.1)
      twoPointers(view, MotionEvent.ACTION_POINTER_UP, b, ViewPoint(second.x + 120.0, second.y + 120.0))
      val beforePan = onMain { checkNotNull(canvas.textTransformSnapshot()).transform }
      for (step in 1..6) touch(view, MotionEvent.ACTION_MOVE, ViewPoint(b.x - step * 15.0, b.y))
      val afterPan = onMain { checkNotNull(canvas.textTransformSnapshot()).transform }
      assertTrue("The remaining finger must pan before it lifts", kotlin.math.abs(afterPan.tx - beforePan.tx) > 5.0)
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
      touch(view, MotionEvent.ACTION_UP, ViewPoint(b.x - 90.0, b.y))
      val current = point(canvas, words[1])
      touch(view, MotionEvent.ACTION_DOWN, current)
      awaitSelection(view, "B")
      touch(view, MotionEvent.ACTION_UP, current)
    }
  }

  @Test fun replacementLongPressSurvivesDismissalOfPreviousMenu() {
    withViewer { view, _, canvas, words ->
      val b = point(canvas, words[1])
      val c = point(canvas, words[2])
      touch(view, MotionEvent.ACTION_DOWN, b)
      awaitSelection(view, "B")
      touch(view, MotionEvent.ACTION_UP, b)
      touch(view, MotionEvent.ACTION_DOWN, c)
      awaitSelection(view, "C")
      instrumentation.waitForIdleSync()
      assertEquals("C", onMain { view.sourceSelection.selectedCopyText() })
      touch(view, MotionEvent.ACTION_UP, c)
      instrumentation.waitForIdleSync()
      assertEquals("C", onMain { view.sourceSelection.selectedCopyText() })
    }
  }

  @Test fun blankPageDoesNotCreateSelectionOrMenu() {
    withViewer(content = "", expectedWords = emptyList()) { view, _, _, _ ->
      val point = ViewPoint(300.0, 400.0)
      touch(view, MotionEvent.ACTION_DOWN, point)
      waitPastLongPress()
      touch(view, MotionEvent.ACTION_UP, point)
      assertNull(onMain { view.sourceSelection.selectedCopyText() })
    }
  }

  @Test fun croppedCanonicalHitWorksAtEveryQuarterTurn() {
    for (rotation in listOf(0, 90, 180, 270)) {
      withViewer(rotation) { view, _, canvas, words ->
        val b = point(canvas, words[1])
        touch(view, MotionEvent.ACTION_DOWN, b)
        awaitSelection(view, "B")
        touch(view, MotionEvent.ACTION_UP, b)
        assertEquals("B", onMain { view.sourceSelection.selectedCopyText() })
      }
    }
  }

  private fun withViewer(rotation: Int = 0,
    content: String = "BT /F1 24 Tf 1 0 0 1 40 300 Tm (A B C) Tj ET\n",
    expectedWords: List<String> = listOf("A", "B", "C"),
    body: (HybridInkSignView, HybridInkSignDocument, ViewerCanvas, List<SourceTextWord>) -> Unit) {
    NativeTestRuntime.initialize()
    val source = File.createTempFile("source-selection-", ".pdf", instrumentation.targetContext.cacheDir)
    source.writeBytes(textPagePdf(content,
      pageWidth = 300, pageHeight = 400, cropBox = "20 20 280 380", rotation = rotation))
    val document = await { HybridInkSignDocument(instrumentation.targetContext).initializeSource(source.path) } as HybridInkSignDocument
    val scenario = ActivityScenario.launch(LowLatencyInkSmokeActivity::class.java)
    lateinit var view: HybridInkSignView
    var viewerCreated = false
    lateinit var canvas: ViewerCanvas
    try {
      scenario.onActivity { activity ->
        view = HybridInkSignView(activity)
        viewerCreated = true
        activity.content.addView(view.view, FrameLayout.LayoutParams(600, 800))
        view.document = Variant_HybridInkSignDocumentSpec_DocumentOptions.First(document)
        canvas = (view.view as FrameLayout).getChildAt(0) as ViewerCanvas
      }
      instrumentation.waitForIdleSync()
      val prepared = await { document.getPage(PageQuery.create(0.0)) } as HybridDocumentPage
      val words = onMain { prepared.context.sourceWords.words }
      assertEquals(expectedWords, words.map { it.text })
      body(view, document, canvas, words)
    } finally {
      onMain { if (viewerCreated) view.onDropView() }
      scenario.close()
      await { document.close() }
      source.delete()
    }
  }

  private fun point(canvas: ViewerCanvas, word: SourceTextWord): ViewPoint = onMain {
    val snapshot = checkNotNull(canvas.textTransformSnapshot())
    val rect = word.rectangles.first()
    PageCoordinates(snapshot.page).rawToView(snapshot.transform).map(
      PagePoint((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2))
  }

  private var downTime = 0L
  private fun twoPointers(view: HybridInkSignView, action: Int, first: ViewPoint, second: ViewPoint) = onMain {
    val properties = Array(2) { index -> MotionEvent.PointerProperties().apply { id = index; toolType = MotionEvent.TOOL_TYPE_FINGER } }
    val coordinates = Array(2) { index -> MotionEvent.PointerCoords().apply {
      val point = if (index == 0) first else second
      x = point.x.toFloat(); y = point.y.toFloat(); pressure = 1f; size = 1f
    } }
    val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(),
      if (action == MotionEvent.ACTION_MOVE) action else action or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
      2, properties, coordinates,
      0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
    try { view.view.dispatchTouchEvent(event) } finally { event.recycle() }
  }

  private fun touch(view: HybridInkSignView, action: Int, point: ViewPoint) = onMain {
    val now = SystemClock.uptimeMillis()
    if (action == MotionEvent.ACTION_DOWN) downTime = now
    val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER }
    val coordinates = MotionEvent.PointerCoords().apply { x = point.x.toFloat(); y = point.y.toFloat(); pressure = 1f; size = 1f }
    val event = MotionEvent.obtain(downTime, now, action, 1, arrayOf(properties), arrayOf(coordinates),
      0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
    try { view.view.dispatchTouchEvent(event) } finally { event.recycle() }
  }

  private fun waitPastLongPress() { SystemClock.sleep(ViewConfiguration.getLongPressTimeout() + 150L) }
  private fun awaitSelection(view: HybridInkSignView, expected: String) {
    val deadline = SystemClock.uptimeMillis() + 5000
    while (SystemClock.uptimeMillis() < deadline) {
      if (onMain { view.sourceSelection.selectedCopyText() } == expected) return
      SystemClock.sleep(20)
    }
    assertEquals(expected, onMain { view.sourceSelection.selectedCopyText() })
  }

  private fun clickCopy() {
    val label = instrumentation.targetContext.getString(android.R.string.copy)
    val deadline = SystemClock.uptimeMillis() + 5000
    while (SystemClock.uptimeMillis() < deadline) {
      fun find(node: AccessibilityNodeInfo?): Boolean {
        if (node == null) return false
        if (node.text?.toString() == label && node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
        return (0 until node.childCount).any { find(node.getChild(it)) }
      }
      if (find(instrumentation.uiAutomation.rootInActiveWindow)) { instrumentation.waitForIdleSync(); return }
      SystemClock.sleep(20)
    }
    fail("Native Copy action was not available")
  }

  private fun <T> onMain(block: () -> T): T {
    val result = AtomicReference<T>()
    instrumentation.runOnMainSync { result.set(block()) }
    return result.get()
  }

  private fun <T : Any> await(request: () -> Promise<T>): T {
    val done = CountDownLatch(1)
    val value = AtomicReference<T>()
    val failure = AtomicReference<Throwable>()
    instrumentation.runOnMainSync { request().then { value.set(it); done.countDown() }.catch { failure.set(it); done.countDown() } }
    assertTrue(done.await(30, TimeUnit.SECONDS))
    failure.get()?.let { throw it }
    return checkNotNull(value.get())
  }
}
