#pragma once

#include <cstddef>
#include <string>

#include "pdfium/PositionedTextModel.hpp"

namespace margelo::nitro::inksignpdf::pdfium {

/** Returns a bounded code-point/geometry dump for native debug diagnostics. */
std::string dumpPositionedPageDiagnostics(
    const PositionedPage& page,
    std::size_t maxCharacters = 128);

}  // namespace margelo::nitro::inksignpdf::pdfium
