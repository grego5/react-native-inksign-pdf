package com.margelo.nitro.inksignpdf

import android.graphics.Typeface
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URI
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/** Resolves an app-shared local font file, downloading the fallback only when needed. */
internal class AndroidFallbackFontResolver(
  private val fontValidator: (File) -> Boolean = {
    runCatching { Typeface.createFromFile(it); true }.getOrDefault(false)
  },
  private val openConnection: (URL) -> HttpURLConnection = {
    it.openConnection() as HttpURLConnection
  },
) {
  suspend fun resolve(font: AndroidFallbackFont): PdfFallbackFont = withContext(Dispatchers.IO) {
    val destination = destinationFile(font.uri)
    val lock = destinationLocks.computeIfAbsent(destination.path) { Mutex() }
    lock.withLock {
      coroutineContext.ensureActive()
      val collectionIndex = font.collectionIndex ?: 0.0
      if (!collectionIndex.isFinite() || collectionIndex < 0.0) {
        throw PdfSessionException("invalid_fallback_font", "The font collection index is invalid")
      }
      if (!isUsableFont(destination)) download(font.url, destination)
      PdfFallbackFont(destination.path, collectionIndex)
    }
  }

  private fun destinationFile(uri: String): File {
    val source = if (uri.startsWith("file:", ignoreCase = true)) {
      try {
        File(URI(uri).path)
      } catch (error: Exception) {
        throw PdfSessionException("invalid_fallback_font_uri", "The font URI has no local file path", error)
      }
    } else if (SCHEME_REGEX.containsMatchIn(uri) && !WINDOWS_DRIVE_PATH.containsMatchIn(uri)) {
      throw PdfSessionException(
        "invalid_fallback_font_uri",
        "The font URI must identify an app-accessible local file",
      )
    } else {
      File(uri)
    }
    if (!source.isAbsolute) {
      throw PdfSessionException("invalid_fallback_font_uri", "The font URI is not a file destination")
    }
    val file = source.canonicalFile
    if (file == file.parentFile) {
      throw PdfSessionException("invalid_fallback_font_uri", "The font URI is not a file destination")
    }
    return file
  }

  private fun isUsableFont(file: File): Boolean {
    if (!file.isFile || file.length() <= 0L) return false
    return runCatching { fontValidator(file) }.getOrDefault(false)
  }

  private suspend fun download(urlString: String, destination: File) {
    val url = try {
      URL(urlString)
    } catch (error: Exception) {
      throw PdfSessionException("invalid_fallback_font_url", "The fallback font URL is invalid", error)
    }
    if (url.protocol != "http" && url.protocol != "https") {
      throw PdfSessionException("invalid_fallback_font_url", "The fallback font URL must use HTTP or HTTPS")
    }
    val parent = destination.parentFile
      ?: throw PdfSessionException("invalid_fallback_font_uri", "The font URI has no parent directory")
    if (!parent.isDirectory && !parent.mkdirs()) {
      throw PdfSessionException("fallback_font_download_failed", "Unable to create the font cache directory")
    }

    val connection = openConnection(url)
    connection.connectTimeout = CONNECT_TIMEOUT_MS
    connection.readTimeout = READ_TIMEOUT_MS
    connection.instanceFollowRedirects = true
    var partial: File? = null
    try {
      connection.connect()
      if (connection.responseCode !in 200..299) {
        throw PdfSessionException("fallback_font_download_failed", "The fallback font request failed")
      }
      if (connection.contentLengthLong > MAX_FONT_BYTES) {
        throw PdfSessionException("fallback_font_download_failed", "The fallback font exceeds the size limit")
      }
      val temporaryFile = File.createTempFile(".inksign-font-", ".partial", parent)
      partial = temporaryFile
      BufferedInputStream(connection.inputStream).use { input ->
        FileOutputStream(temporaryFile).use { output ->
          val buffer = ByteArray(BUFFER_SIZE)
          var total = 0L
          while (true) {
            coroutineContext.ensureActive()
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > MAX_FONT_BYTES) {
              throw PdfSessionException("fallback_font_download_failed", "The fallback font exceeds the size limit")
            }
            output.write(buffer, 0, count)
          }
          output.fd.sync()
        }
      }
      if (!isUsableFont(temporaryFile)) {
        throw PdfSessionException("invalid_fallback_font", "The downloaded file is not a usable font")
      }
      coroutineContext.ensureActive()
      if (isUsableFont(destination)) return
      if (destination.exists() && !destination.delete()) {
        throw PdfSessionException("fallback_font_download_failed", "Unable to replace the invalid cached font")
      }
      if (!temporaryFile.renameTo(destination)) {
        throw PdfSessionException("fallback_font_download_failed", "Unable to publish the downloaded font")
      }
      partial = null
    } catch (error: PdfSessionException) {
      throw error
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      throw PdfSessionException("fallback_font_download_failed", "Unable to download the fallback font", error)
    } finally {
      connection.disconnect()
      partial?.delete()
    }
  }

  private companion object {
    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 15_000
    private const val MAX_FONT_BYTES = 64L * 1024L * 1024L
    private const val BUFFER_SIZE = 16 * 1024
    private val SCHEME_REGEX = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")
    private val WINDOWS_DRIVE_PATH = Regex("^[A-Za-z]:[\\\\/]")
    private val destinationLocks = ConcurrentHashMap<String, Mutex>()
  }
}
