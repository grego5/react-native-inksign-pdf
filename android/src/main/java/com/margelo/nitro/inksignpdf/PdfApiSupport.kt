package com.margelo.nitro.inksignpdf

import android.os.Build
import android.os.ext.SdkExtensions

internal object PdfApiSupport {
  const val unsupportedCode = "unsupported_android_pdf_api"

  fun requireSupported() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
      SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) < 18
    ) {
      throw IllegalStateException(
        "$unsupportedCode: Android S extension 18 is required for PDF operations",
      )
    }
  }
}
