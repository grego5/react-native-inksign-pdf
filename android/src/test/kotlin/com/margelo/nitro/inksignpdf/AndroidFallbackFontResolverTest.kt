package com.margelo.nitro.inksignpdf

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AndroidFallbackFontResolverTest {
  @get:Rule val temporaryFolder = TemporaryFolder()

  @Test
  fun validReactPreloadedUriIsReusedWithoutFetchingUrl() = runBlocking {
    val destination = temporaryFolder.newFile("shared-font.ttf").apply { writeText(VALID_FONT) }
    val requestCount = AtomicInteger()
    val resolver = resolver(requestCount, VALID_FONT)

    val resolved = resolver.resolve(font(destination))

    assertEquals(destination.canonicalPath, resolved.path)
    assertEquals(3.0, resolved.collectionIndex!!, 0.0)
    assertEquals(0, requestCount.get())
  }

  @Test
  fun missingUriDownloadsToSharedDestinationThenReusesIt() = runBlocking {
    val destination = File(temporaryFolder.root, "shared/cache/font.ttf")
    val requestCount = AtomicInteger()
    val resolver = resolver(requestCount, VALID_FONT)

    val first = resolver.resolve(font(destination))
    val second = resolver.resolve(font(destination))

    assertEquals(destination.canonicalPath, first.path)
    assertEquals(first, second)
    assertEquals(VALID_FONT, destination.readText())
    assertEquals(1, requestCount.get())
    assertTrue(temporaryFolder.root.walkTopDown().none { it.name.endsWith(".partial") })
  }

  @Test
  fun invalidDownloadIsNotPublishedAndPartialFileIsRemoved() = runBlocking {
    val destination = File(temporaryFolder.root, "shared/cache/font.ttf")
    val requestCount = AtomicInteger()
    val resolver = resolver(requestCount, "not a font")

    val failure = runCatching { resolver.resolve(font(destination)) }.exceptionOrNull()

    assertTrue(failure is PdfSessionException)
    assertEquals("invalid_fallback_font", (failure as PdfSessionException).code)
    assertFalse(destination.exists())
    assertEquals(1, requestCount.get())
    assertTrue(temporaryFolder.root.walkTopDown().none { it.name.endsWith(".partial") })
  }

  @Test
  fun nonFileUriAndInvalidUrlFailBeforePublishing() = runBlocking {
    val requestCount = AtomicInteger()
    val resolver = resolver(requestCount, VALID_FONT)
    val invalidUri = font(File(temporaryFolder.root, "unused.ttf")).copy(
      uri = "content://example.test/fonts/fallback.ttf",
    )
    val uriFailure = runCatching { resolver.resolve(invalidUri) }.exceptionOrNull()

    assertTrue(uriFailure is PdfSessionException)
    assertEquals("invalid_fallback_font_uri", (uriFailure as PdfSessionException).code)
    assertEquals(0, requestCount.get())

    val destination = File(temporaryFolder.root, "invalid-url/font.ttf")
    val invalidUrl = font(destination).copy(url = "file:///fonts/fallback.ttf")
    val urlFailure = runCatching { resolver.resolve(invalidUrl) }.exceptionOrNull()

    assertTrue(urlFailure is PdfSessionException)
    assertEquals("invalid_fallback_font_url", (urlFailure as PdfSessionException).code)
    assertFalse(destination.exists())
    assertTrue(temporaryFolder.root.walkTopDown().none { it.name.endsWith(".partial") })
  }

  @Test
  fun unwritableDestinationRejectsWithoutFetching() = runBlocking {
    val blocker = temporaryFolder.newFile("not-a-directory").apply { writeText("file") }
    val requestCount = AtomicInteger()
    val resolver = resolver(requestCount, VALID_FONT)

    val failure = runCatching {
      resolver.resolve(font(File(blocker, "fallback.ttf")))
    }.exceptionOrNull()

    assertTrue(failure is PdfSessionException)
    assertEquals("fallback_font_download_failed", (failure as PdfSessionException).code)
    assertEquals(0, requestCount.get())
  }

  @Test
  fun unsuccessfulHttpResponseAndInvalidCollectionIndexDoNotCreateCacheFiles() = runBlocking {
    val destination = File(temporaryFolder.root, "shared/cache/font.ttf")
    val requestCount = AtomicInteger()
    val resolver = AndroidFallbackFontResolver(
      fontValidator = { it.readText() == VALID_FONT },
      openConnection = { url ->
        requestCount.incrementAndGet()
        MemoryHttpConnection(url, VALID_FONT.toByteArray(StandardCharsets.UTF_8), statusCode = 404)
      },
    )

    val responseFailure = runCatching { resolver.resolve(font(destination)) }.exceptionOrNull()
    assertTrue(responseFailure is PdfSessionException)
    assertEquals("fallback_font_download_failed", (responseFailure as PdfSessionException).code)
    assertFalse(destination.exists())
    assertTrue(temporaryFolder.root.walkTopDown().none { it.name.endsWith(".partial") })

    val indexFailure = runCatching {
      resolver.resolve(font(destination).copy(collectionIndex = -1.0))
    }.exceptionOrNull()
    assertTrue(indexFailure is PdfSessionException)
    assertEquals("invalid_fallback_font", (indexFailure as PdfSessionException).code)
    assertEquals(1, requestCount.get())
  }

  @Test
  fun concurrentViewsReuseOneCompletedDownload() = runBlocking {
    val destination = File(temporaryFolder.root, "shared/cache/font.ttf")
    val requestCount = AtomicInteger()
    val requestStarted = CountDownLatch(1)
    val releaseDownload = CountDownLatch(1)
    fun resolverForView() = AndroidFallbackFontResolver(
      fontValidator = { it.readText() == VALID_FONT },
      openConnection = { url ->
        requestCount.incrementAndGet()
        MemoryHttpConnection(
          url,
          BlockingInputStream(VALID_FONT.toByteArray(StandardCharsets.UTF_8), requestStarted, releaseDownload),
        )
      },
    )

    try {
      val firstView = async(Dispatchers.IO) { resolverForView().resolve(font(destination)) }
      assertTrue(requestStarted.await(5, TimeUnit.SECONDS))
      val secondStarted = CountDownLatch(1)
      val secondView = async(Dispatchers.IO) {
        secondStarted.countDown()
        resolverForView().resolve(font(destination))
      }
      assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
      releaseDownload.countDown()

      assertEquals(destination.canonicalPath, firstView.await().path)
      assertEquals(destination.canonicalPath, secondView.await().path)
      assertEquals(1, requestCount.get())
    } finally {
      releaseDownload.countDown()
    }
  }

  @Test
  fun atomicallyPreloadedUriWinsWhenPublishedDuringDownload() = runBlocking {
    val destination = File(temporaryFolder.root, "shared/cache/font.ttf")
    val requestCount = AtomicInteger()
    val requestStarted = CountDownLatch(1)
    val releaseDownload = CountDownLatch(1)
    val resolver = resolverForExternalPreload(requestCount, requestStarted, releaseDownload)

    try {
      val resolving = async(Dispatchers.IO) { resolver.resolve(font(destination)) }
      assertTrue(requestStarted.await(5, TimeUnit.SECONDS))
      val staged = File(destination.parentFile, "font.external.partial")
      staged.writeText(VALID_FONT + "-from-app")
      assertTrue(staged.renameTo(destination))
      releaseDownload.countDown()

      assertEquals(destination.canonicalPath, resolving.await().path)
      assertEquals(VALID_FONT + "-from-app", destination.readText())
      assertEquals(1, requestCount.get())
      assertTrue(temporaryFolder.root.walkTopDown().none { it.name.endsWith(".partial") })
    } finally {
      releaseDownload.countDown()
    }
  }

  @Test
  fun cancellingOneViewDoesNotPreventAnotherFromResolvingSharedUri() = runBlocking {
    val destination = File(temporaryFolder.root, "shared/cache/font.ttf")
    val requestCount = AtomicInteger()
    val firstRequestStarted = CountDownLatch(1)
    val releaseFirstRequest = CountDownLatch(1)
    fun resolverForView() = AndroidFallbackFontResolver(
      fontValidator = { it.readText() == VALID_FONT },
      openConnection = { url ->
        val request = requestCount.incrementAndGet()
        if (request == 1) {
          MemoryHttpConnection(
            url,
            BlockingInputStream(VALID_FONT.toByteArray(StandardCharsets.UTF_8), firstRequestStarted, releaseFirstRequest),
          )
        } else {
          MemoryHttpConnection(url, VALID_FONT.toByteArray(StandardCharsets.UTF_8))
        }
      },
    )

    try {
      val cancelledView = async(Dispatchers.IO) { resolverForView().resolve(font(destination)) }
      assertTrue(firstRequestStarted.await(5, TimeUnit.SECONDS))
      val secondStarted = CountDownLatch(1)
      val activeView = async(Dispatchers.IO) {
        secondStarted.countDown()
        resolverForView().resolve(font(destination))
      }
      assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
      cancelledView.cancel()
      releaseFirstRequest.countDown()

      val cancellation = runCatching { cancelledView.await() }.exceptionOrNull()
      assertTrue(cancellation is CancellationException)
      assertEquals(destination.canonicalPath, activeView.await().path)
      assertEquals(2, requestCount.get())
      assertEquals(VALID_FONT, destination.readText())
      assertTrue(temporaryFolder.root.walkTopDown().none { it.name.endsWith(".partial") })
    } finally {
      releaseFirstRequest.countDown()
    }
  }

  private fun resolver(requestCount: AtomicInteger, response: String) = AndroidFallbackFontResolver(
    fontValidator = { it.readText() == VALID_FONT },
    openConnection = { url ->
      requestCount.incrementAndGet()
      MemoryHttpConnection(url, response.toByteArray(StandardCharsets.UTF_8))
    },
  )

  private fun resolverForExternalPreload(
    requestCount: AtomicInteger,
    requestStarted: CountDownLatch,
    releaseDownload: CountDownLatch,
  ) = AndroidFallbackFontResolver(
    fontValidator = { it.readText().startsWith(VALID_FONT) },
    openConnection = { url ->
      requestCount.incrementAndGet()
      MemoryHttpConnection(
        url,
        BlockingInputStream(VALID_FONT.toByteArray(StandardCharsets.UTF_8), requestStarted, releaseDownload),
      )
    },
  )

  private fun font(destination: File) = AndroidFallbackFont(
    url = "https://assets.example.test/fonts/fallback.ttf",
    uri = destination.absolutePath,
    collectionIndex = 3.0,
  )

  private class MemoryHttpConnection(
    url: URL,
    private val body: InputStream,
    private val statusCode: Int = 200,
  ) : HttpURLConnection(url) {
    constructor(url: URL, bytes: ByteArray, statusCode: Int = 200) :
      this(url, ByteArrayInputStream(bytes), statusCode)

    override fun disconnect() = Unit
    override fun usingProxy() = false
    override fun connect() { connected = true }
    override fun getInputStream(): InputStream = body
    override fun getResponseCode(): Int = statusCode
    override fun getContentLengthLong(): Long = -1L
  }

  private class BlockingInputStream(
    private val bytes: ByteArray,
    private val entered: CountDownLatch,
    private val release: CountDownLatch,
  ) : InputStream() {
    private var offset = 0

    override fun read(): Int {
      val singleByte = ByteArray(1)
      val count = read(singleByte, 0, 1)
      return if (count < 0) -1 else singleByte[0].toInt() and 0xff
    }

    override fun read(buffer: ByteArray, start: Int, length: Int): Int {
      if (offset == 0) {
        entered.countDown()
        if (!release.await(5, TimeUnit.SECONDS)) throw java.io.IOException("test download was not released")
      }
      if (offset >= bytes.size) return -1
      val count = minOf(length, bytes.size - offset)
      bytes.copyInto(buffer, start, offset, offset + count)
      offset += count
      return count
    }
  }

  private companion object {
    const val VALID_FONT = "valid-font-data"
  }
}
