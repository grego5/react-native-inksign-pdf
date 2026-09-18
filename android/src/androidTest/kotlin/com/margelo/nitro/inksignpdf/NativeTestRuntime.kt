package com.margelo.nitro.inksignpdf

import com.facebook.soloader.nativeloader.NativeLoader
import com.facebook.soloader.nativeloader.SystemDelegate
import com.margelo.nitro.JNIOnLoad

internal object NativeTestRuntime {
  @JvmStatic
  external fun pdfiumSmokeNative(): Boolean

  fun initialize() {
    if (!NativeLoader.isInitialized()) {
      NativeLoader.init(SystemDelegate())
    }
    JNIOnLoad.initializeNativeNitro()
    ReactNativeInkSignPdfOnLoad.initializeNative()
  }
}
