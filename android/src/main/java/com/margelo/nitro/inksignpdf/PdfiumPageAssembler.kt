package com.margelo.nitro.inksignpdf

import java.io.File

internal enum class PdfiumAssemblyOperation(val value: Int) {
  APPEND(0),
  REMOVE(1),
  MOVE(2),
  CREATE(3),
}

internal data class PdfiumAppendRequest(
  val type: PageType,
  val sourcePath: String? = null,
  val imageBytes: ByteArray? = null,
  val pageWidth: Double = 0.0,
  val pageHeight: Double = 0.0,
  val placement: PdfiumImagePlacement = PdfiumImagePlacement(),
)

internal data class PdfiumImagePlacement(
  val a: Double = 1.0,
  val b: Double = 0.0,
  val c: Double = 0.0,
  val d: Double = 1.0,
  val e: Double = 0.0,
  val f: Double = 0.0,
)

internal data class PdfiumAssemblyRequest(
  val operation: PdfiumAssemblyOperation,
  val appendInputs: List<PdfiumAppendRequest> = emptyList(),
  val pageIndex: Int = 0,
  val destinationIndex: Int = 0,
)

/** Synchronous JNI boundary for one worker-owned, transactional PDF mutation. */
internal object PdfiumPageAssembler {
  fun assemble(
    input: File?,
    request: PdfiumAssemblyRequest,
    scratch: File,
  ): List<PdfPageDimensions> {
    request.appendInputs.forEach { item ->
      when (item.type) {
        PageType.PDF -> require(!item.sourcePath.isNullOrBlank() && item.imageBytes == null)
        PageType.IMAGE -> require(item.sourcePath == null && item.imageBytes?.isNotEmpty() == true)
      }
    }
    val appendPaths = request.appendInputs.map { it.sourcePath }.toTypedArray()
    val appendBytes = request.appendInputs.map { it.imageBytes }.toTypedArray()
    val appendTypes = IntArray(request.appendInputs.size) { index ->
      when (request.appendInputs[index].type) {
        PageType.PDF -> 0
        PageType.IMAGE -> 1
      }
    }
    val appendMetadata = DoubleArray(request.appendInputs.size * 8)
    request.appendInputs.forEachIndexed { index, item ->
      val offset = index * 8
      appendMetadata[offset] = item.pageWidth
      appendMetadata[offset + 1] = item.pageHeight
      appendMetadata[offset + 2] = item.placement.a
      appendMetadata[offset + 3] = item.placement.b
      appendMetadata[offset + 4] = item.placement.c
      appendMetadata[offset + 5] = item.placement.d
      appendMetadata[offset + 6] = item.placement.e
      appendMetadata[offset + 7] = item.placement.f
    }
    val flattened = try {
      nativeAssemble(
        input?.path ?: "",
        request.operation.value,
        appendPaths,
        appendBytes,
        appendTypes,
        appendMetadata,
        request.pageIndex,
        request.destinationIndex,
        scratch.absolutePath,
      )
    } catch (error: PdfSessionException) {
      throw error
    } catch (error: IllegalArgumentException) {
      throw PdfSessionException("invalid_assembly", error.message ?: "Invalid PDF mutation", error)
    } catch (error: IllegalStateException) {
      throw PdfSessionException("pdf_mutation_failed", error.message ?: "PDF mutation failed", error)
    }
    return decodePageDimensions(flattened)
  }

  internal fun decodePageDimensions(flattened: DoubleArray): List<PdfPageDimensions> {
    if (flattened.size % 3 != 0 || flattened.isEmpty()) {
      throw PdfSessionException(
        "pdf_mutation_failed",
        "PDFium returned invalid mutation metadata",
      )
    }
    return List(flattened.size / 3) { index ->
      val offset = index * 3
      PdfPageDimensions(flattened[offset], flattened[offset + 1])
    }
  }

  @JvmStatic
  private external fun nativeAssemble(
    inputPath: String,
    operation: Int,
    appendPaths: Array<String?>,
    appendBytes: Array<ByteArray?>,
    appendTypes: IntArray,
    appendMetadata: DoubleArray,
    pageIndex: Int,
    destinationIndex: Int,
    scratchPath: String,
  ): DoubleArray
}
