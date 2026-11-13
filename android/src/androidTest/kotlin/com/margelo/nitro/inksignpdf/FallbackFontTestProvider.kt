package com.margelo.nitro.inksignpdf

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File

/** Test-APK-only provider exposing the packaged font through Android's content resolver. */
class FallbackFontTestProvider : ContentProvider() {
  override fun onCreate() = true

  override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
    require(mode == "r")
    val context = checkNotNull(this.context)
    val font = File(context.cacheDir, "inksign-provider-font.ttf")
    val id = context.resources.getIdentifier("inksign_fallback", "raw", context.packageName)
    context.resources.openRawResource(id).use { input ->
      font.outputStream().use { output -> input.copyTo(output) }
    }
    return ParcelFileDescriptor.open(font, ParcelFileDescriptor.MODE_READ_ONLY)
  }

  override fun getType(uri: Uri) = "font/ttf"
  override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
    selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
  override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
  override fun update(uri: Uri, values: ContentValues?, selection: String?,
    selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
  override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
    throw UnsupportedOperationException()
}
