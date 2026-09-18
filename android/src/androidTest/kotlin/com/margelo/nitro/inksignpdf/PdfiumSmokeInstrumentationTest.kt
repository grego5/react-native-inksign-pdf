package com.margelo.nitro.inksignpdf

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SmallTest
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SmallTest
class PdfiumSmokeInstrumentationTest {
  @Before
  fun loadNativeModule() {
    NativeTestRuntime.initialize()
  }

  @Test
  fun finalNativeModuleInitializesAndDestroysPdfium() {
    assertTrue(NativeTestRuntime.pdfiumSmokeNative())
  }
}
