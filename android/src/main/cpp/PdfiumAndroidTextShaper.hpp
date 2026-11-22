#pragma once

#include "pdfium-adapter/PdfiumContentWriter.hpp"

margelo::nitro::inksignpdf::pdfium::PdfiumShapedRun shapeAndroidPdfText(
    std::size_t runIndex, std::span<const std::uint8_t> fontBytes,
    std::u16string_view text, bool rtl, float fontSize);
