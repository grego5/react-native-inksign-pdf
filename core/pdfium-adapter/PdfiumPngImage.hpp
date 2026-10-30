#pragma once

#include "pdfium-adapter/PdfiumPageAssembler.hpp"
#include <span>

namespace margelo::nitro::inksignpdf::pdfium {

// Wraps a non-interlaced 4-bit grayscale PNG's compressed samples in a PDF page.
// Input bytes remain caller-owned; the returned PDF owns its copied image stream.
PdfiumError makeGrayscalePngPage(const PdfiumAppendInput& input,
                                std::vector<std::uint8_t>& pdf);

// Synchronous encoding of opaque gray pixels; the caller retains the raster.
PdfiumError encodeGrayscalePng4(std::span<const std::uint8_t> pixels,
                                int width, int height, std::size_t rowStride,
                                std::size_t pixelStride,
                                std::vector<std::uint8_t>& png);

}  // namespace margelo::nitro::inksignpdf::pdfium
