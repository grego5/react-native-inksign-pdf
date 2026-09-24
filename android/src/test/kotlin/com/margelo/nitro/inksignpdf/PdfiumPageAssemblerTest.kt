package com.margelo.nitro.inksignpdf

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class PdfiumPageAssemblerTest {
  @Test
  fun decodesOrderedPageMetadataTriples() {
    assertEquals(
      listOf(PdfPageDimensions(100.0, 200.0), PdfPageDimensions(300.0, 400.0)),
      PdfiumPageAssembler.decodePageDimensions(
        doubleArrayOf(100.0, 200.0, 0.0, 300.0, 400.0, 1.0),
      ),
    )
  }

  @Test
  fun rejectsMalformedNativeMetadata() {
    try {
      PdfiumPageAssembler.decodePageDimensions(doubleArrayOf(100.0, 200.0))
      fail("Expected malformed metadata to be rejected")
    } catch (error: PdfSessionException) {
      assertEquals("pdf_mutation_failed", error.code)
    }
  }
}
