#pragma once

#include <cstddef>
#include <mutex>

namespace margelo::nitro::inksignpdf::pdfium {

struct PdfiumLibraryState final {
  std::mutex lifecycleMutex;
  std::mutex apiMutex;
  std::size_t activeLeases = 0;
};

PdfiumLibraryState& pdfiumLibraryState();

}  // namespace margelo::nitro::inksignpdf::pdfium
