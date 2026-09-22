package com.margelo.nitro.inksignpdf

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import androidx.activity.result.ActivityResult
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidPageInputCoordinatorTest {
  @Test
  fun pickerIntentUsesBothMimeTypesWhenUnrestricted() {
    val intent = AndroidPageInputCoordinator.buildPagePickerIntent(null)

    assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
    assertEquals("*/*", intent.type)
    assertTrue(intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
    assertArrayEquals(
      arrayOf("application/pdf", "image/*"),
      intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES),
    )
  }

  @Test
  fun pickerIntentRestrictsSingleType() {
    assertEquals(
      "application/pdf",
      AndroidPageInputCoordinator.buildPagePickerIntent(PageType.PDF).type,
    )
    assertEquals(
      "image/*",
      AndroidPageInputCoordinator.buildPagePickerIntent(PageType.IMAGE).type,
    )
  }

  @Test
  fun pickerUrisPreserveDataThenClipOrderAndRemoveDuplicates() {
    val first = Uri.parse("content://example/first")
    val second = Uri.parse("content://example/second")
    val third = Uri.parse("content://example/third")
    val intent = Intent().setData(first).apply {
      clipData = ClipData.newRawUri("pages", first).also { clip ->
        clip.addItem(ClipData.Item(second))
        clip.addItem(ClipData.Item(third))
      }
    }

    assertEquals(
      listOf(first, second, third),
      AndroidPageInputCoordinator.extractOrderedUris(intent),
    )
  }

  @Test
  fun localSourcesAreCopiedInOrderAndSniffed() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val policy = CacheArtifactPolicy.initialize(context)
    val sourceRoot = File(context.cacheDir, "page-input-test-${UUID.randomUUID()}")
    sourceRoot.mkdirs()
    val pdf = File(sourceRoot, "first.bin").apply {
      writeText("%PDF-1.7\n")
    }
    val image = File(sourceRoot, "second.bin").apply {
      val bytes = ByteArrayOutputStream()
      Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).compress(
        Bitmap.CompressFormat.PNG,
        100,
        bytes,
      )
      writeBytes(bytes.toByteArray())
    }
    val coordinator = AndroidPageInputCoordinator(context, policy)
    var staged = emptyList<StagedPageInput>()
    try {
      instrumentation.runOnMainSync {
        staged = runBlocking {
          coordinator.stage(
            AddPagesOptions(null, arrayOf(pdf.absolutePath, image.absolutePath)),
          )
        }
      }
      assertEquals(listOf(PageType.PDF, PageType.IMAGE), staged.map { it.type })
      assertTrue(staged.all { it.file.isFile && it.file.length() > 0L })
      staged.forEach { policy.deleteExact(it.file) }
    } finally {
      instrumentation.runOnMainSync { coordinator.close() }
      sourceRoot.deleteRecursively()
    }
  }

  @Test
  fun stalePickerResultCannotSettleANewerRequest() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val callbacks = mutableListOf<(ActivityResult) -> Unit>()
    val unregisterCount = intArrayOf(0)
    val registrar = PagePickerRegistrar { _, callback ->
      callbacks += callback
      object : PagePickerHandle {
        override fun launch(intent: Intent) = Unit

        override fun unregister() {
          unregisterCount[0]++
        }
      }
    }
    val coordinator = AndroidPageInputCoordinator(
      context,
      CacheArtifactPolicy.initialize(context),
      registrar,
    )
    var first: Result<List<StagedPageInput>>? = null
    var second: Result<List<StagedPageInput>>? = null

    try {
      instrumentation.runOnMainSync {
        runBlocking {
          val firstJob = launch { first = runCatching { coordinator.stage(null) } }
          yield()
          coordinator.cancelPending()
          firstJob.join()

          val secondJob = launch { second = runCatching { coordinator.stage(null) } }
          yield()
          assertEquals(2, callbacks.size)
          callbacks[0](ActivityResult(Activity.RESULT_CANCELED, null))
          yield()
          assertFalse(secondJob.isCompleted)
          callbacks[1](ActivityResult(Activity.RESULT_CANCELED, null))
          secondJob.join()
        }
      }
    } finally {
      instrumentation.runOnMainSync { coordinator.close() }
    }

    assertEquals(
      "operation_cancelled",
      (first!!.exceptionOrNull() as PdfSessionException).code,
    )
    assertTrue(second!!.isSuccess)
    assertTrue(second!!.getOrThrow().isEmpty())
    assertTrue(unregisterCount[0] >= 2)
  }

  @Test
  fun concurrentRequestIsRejectedAndMalformedResultFails() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val callbacks = mutableListOf<(ActivityResult) -> Unit>()
    val registrar = PagePickerRegistrar { _, callback ->
      callbacks += callback
      object : PagePickerHandle {
        override fun launch(intent: Intent) = Unit
        override fun unregister() = Unit
      }
    }
    val coordinator = AndroidPageInputCoordinator(
      context,
      CacheArtifactPolicy.initialize(context),
      registrar,
    )
    var first: Result<List<StagedPageInput>>? = null
    var rejected: Result<List<StagedPageInput>>? = null
    var malformed: Result<List<StagedPageInput>>? = null

    try {
      instrumentation.runOnMainSync {
        runBlocking {
          val firstJob = launch { first = runCatching { coordinator.stage(null) } }
          yield()
          rejected = runCatching { coordinator.stage(null) }
          coordinator.cancelPending()
          firstJob.join()

          val malformedJob = launch { malformed = runCatching { coordinator.stage(null) } }
          yield()
          callbacks.last()(ActivityResult(Activity.RESULT_OK, null))
          malformedJob.join()
        }
      }
    } finally {
      instrumentation.runOnMainSync { coordinator.close() }
    }

    assertEquals(
      "operation_in_progress",
      (rejected!!.exceptionOrNull() as PdfSessionException).code,
    )
    assertEquals(
      "operation_cancelled",
      (first!!.exceptionOrNull() as PdfSessionException).code,
    )
    assertEquals(
      "malformed_picker_result",
      (malformed!!.exceptionOrNull() as PdfSessionException).code,
    )
  }

  @Test
  fun pickerStagesThroughAControllableSourceProvider() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val callbacks = mutableListOf<(ActivityResult) -> Unit>()
    val registrar = PagePickerRegistrar { _, callback ->
      callbacks += callback
      object : PagePickerHandle {
        override fun launch(intent: Intent) = Unit
        override fun unregister() = Unit
      }
    }
    val coordinator = AndroidPageInputCoordinator(
      context,
      CacheArtifactPolicy.initialize(context),
      registrar,
    ) { ByteArrayInputStream("%PDF-1.7\n".toByteArray()) }
    var result: Result<List<StagedPageInput>>? = null

    try {
      instrumentation.runOnMainSync {
        runBlocking {
          val job = launch { result = runCatching { coordinator.stage(null) } }
          yield()
          callbacks.single()(ActivityResult(
            Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://fake/provider/page.pdf")),
          ))
          job.join()
        }
      }
    } finally {
      instrumentation.runOnMainSync { coordinator.close() }
    }

    val staged = result!!.getOrThrow()
    assertEquals(listOf(PageType.PDF), staged.map { it.type })
    staged.forEach { CacheArtifactPolicy.initialize(context).deleteExact(it.file) }
  }

  @Test
  fun disposalCancelsAnActivePickerRequest() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val registrar = PagePickerRegistrar { _, _ ->
      object : PagePickerHandle {
        override fun launch(intent: Intent) = Unit
        override fun unregister() = Unit
      }
    }
    val coordinator = AndroidPageInputCoordinator(
      context,
      CacheArtifactPolicy.initialize(context),
      registrar,
    )
    var result: Result<List<StagedPageInput>>? = null

    instrumentation.runOnMainSync {
      runBlocking {
        val job = launch { result = runCatching { coordinator.stage(null) } }
        yield()
        coordinator.close()
        job.join()
      }
    }

    assertEquals(
      "operation_cancelled",
      (result!!.exceptionOrNull() as PdfSessionException).code,
    )
  }

  @Test
  fun unreadableLocalSourceFailsWithStableError() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val coordinator = AndroidPageInputCoordinator(
      context,
      CacheArtifactPolicy.initialize(context),
    )
    var result: Result<List<StagedPageInput>>? = null

    try {
      instrumentation.runOnMainSync {
        runBlocking {
          result = runCatching {
            coordinator.stage(
              AddPagesOptions(null, arrayOf(
                File(context.cacheDir, "does-not-exist-${UUID.randomUUID()}.pdf").absolutePath,
              )),
            )
          }
        }
      }
    } finally {
      instrumentation.runOnMainSync { coordinator.close() }
    }

    assertEquals(
      "unreadable_source",
      (result!!.exceptionOrNull() as PdfSessionException).code,
    )
  }

  @Test
  fun partialFailureRemovesAllStagedArtifacts() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    val policy = CacheArtifactPolicy.initialize(context)
    val sourceRoot = File(context.cacheDir, "page-input-failure-${UUID.randomUUID()}")
    sourceRoot.mkdirs()
    val valid = File(sourceRoot, "valid.pdf").apply { writeText("%PDF-1.7\n") }
    val invalid = File(sourceRoot, "invalid.bin").apply { writeText("not a document") }
    val before = policy.root.listFiles()
      ?.filter { it.name.startsWith(".input-") }
      ?.map { it.name }
      ?.toSet()
      ?: emptySet()
    val coordinator = AndroidPageInputCoordinator(context, policy)
    var result: Result<List<StagedPageInput>>? = null

    try {
      instrumentation.runOnMainSync {
        runBlocking {
          result = runCatching {
            coordinator.stage(AddPagesOptions(null, arrayOf(valid.absolutePath, invalid.absolutePath)))
          }
        }
      }
    } finally {
      instrumentation.runOnMainSync { coordinator.close() }
      sourceRoot.deleteRecursively()
    }

    assertEquals(
      "unsupported_content",
      (result!!.exceptionOrNull() as PdfSessionException).code,
    )
    val after = policy.root.listFiles()
      ?.filter { it.name.startsWith(".input-") }
      ?.map { it.name }
      ?.toSet()
      ?: emptySet()
    assertEquals(before, after)
  }
}
