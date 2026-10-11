package com.margelo.nitro.inksignpdf

import android.content.Context
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** Reads a font source once; the document retains its bytes for subsequent worker sessions. */
internal class AndroidFallbackFontResolver(
  private val context: Context,
  private val openConnection: (URL) -> HttpURLConnection = {
    it.openConnection() as HttpURLConnection
  },
) {
  suspend fun resolve(font: AndroidFallbackFont): PdfFallbackFont = withContext(Dispatchers.IO) {
    val collectionIndex = font.collectionIndex ?: 0.0
    if (!collectionIndex.isFinite() || collectionIndex < 0.0 ||
      collectionIndex % 1.0 != 0.0
    ) {
      throw PdfSessionException("invalid_fallback_font", "The font collection index must be a non-negative integer")
    }
    coroutineContext.ensureActive()
    try {
      val uri = Uri.parse(font.uri).normalizeScheme()
      val bytes = if (uri.scheme == "http" || uri.scheme == "https") {
        readRemote(font.uri)
      } else {
        openLocal(uri, font.uri).use { readBytes(it) }
      }
      coroutineContext.ensureActive()
      PdfFallbackFont(font.uri, bytes, collectionIndex)
    } catch (error: PdfSessionException) {
      throw error
    } catch (error: CancellationException) {
      throw error
    } catch (error: Exception) {
      throw PdfSessionException("fallback_font_load_failed", "Unable to read the fallback font source", error)
    }
  }

  private fun openLocal(uri: Uri, source: String): InputStream {
    // Expo identifies APK resources using a file URI, not a filesystem location.
    if (uri.scheme == "file" && uri.pathSegments.firstOrNull() == "android_res") {
      val segments = uri.pathSegments
      if (segments.size != 3) {
        throw PdfSessionException("invalid_fallback_font_uri", "The packaged font URI must contain a resource type and name")
      }
      val type = segments[1].substringBefore('-')
      val filename = segments[2]
      return openResource(type, filename.substringBeforeLast('.', filename))
    }
    return when (uri.scheme) {
      "file", "content", "android.resource" -> context.contentResolver.openInputStream(uri)
        ?: throw PdfSessionException("fallback_font_load_failed", "The font source could not be opened")
      null -> if (File(source).isAbsolute) {
        File(source).inputStream()
      } else {
        val resources = context.resources
        val raw = resources.getIdentifier(source, "raw", context.packageName)
        val id = if (raw != 0) raw else resources.getIdentifier(source, "drawable", context.packageName)
        if (id == 0) throw PdfSessionException("fallback_font_load_failed", "The packaged font resource was not found")
        resources.openRawResource(id)
      }
      else -> throw PdfSessionException("invalid_fallback_font_uri", "Unsupported fallback font URI scheme: ${uri.scheme}")
    }
  }

  private fun openResource(type: String, name: String): InputStream {
    val id = context.resources.getIdentifier(name, type, context.packageName)
    if (id == 0) throw PdfSessionException("fallback_font_load_failed", "The packaged font resource was not found")
    return context.resources.openRawResource(id)
  }

  private suspend fun readRemote(source: String): ByteArray {
    val connection = openConnection(URL(source))
    try {
      connection.connectTimeout = 15_000
      connection.readTimeout = 15_000
      connection.instanceFollowRedirects = true
      connection.connect()
      coroutineContext.ensureActive()
      if (connection.responseCode !in 200..299) {
        throw PdfSessionException("fallback_font_load_failed", "The fallback font request failed")
      }
      if (connection.contentLengthLong > MAX_FONT_BYTES) {
        throw PdfSessionException("invalid_fallback_font", "The fallback font exceeds the size limit")
      }
      return connection.inputStream.use { readBytes(it) }
    } finally {
      connection.disconnect()
    }
  }

  private suspend fun readBytes(input: InputStream): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(16 * 1024)
    while (true) {
      coroutineContext.ensureActive()
      val count = input.read(buffer)
      if (count < 0) break
      if (output.size().toLong() + count > MAX_FONT_BYTES) {
        throw PdfSessionException("invalid_fallback_font", "The fallback font exceeds the size limit")
      }
      output.write(buffer, 0, count)
    }
    if (output.size() == 0) throw PdfSessionException("invalid_fallback_font", "The fallback font is empty")
    return output.toByteArray()
  }

  private companion object {
    private const val MAX_FONT_BYTES = 64L * 1024L * 1024L
  }
}
