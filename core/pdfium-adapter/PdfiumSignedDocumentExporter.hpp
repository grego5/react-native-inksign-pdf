#pragma once

#include "pdfium-adapter/PdfiumDocumentSession.hpp"

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

/** A cropped, top-left-origin BGRA ink bitmap in canonical page coordinates. */
struct PdfiumInkBitmap final {
  // Borrowed from the Objective-C++ page-input array for the synchronous
  // write() call. Components are independent BGRA bytes, not premultiplied.
  std::span<std::uint8_t> bgra;
  int width = 0;
  int height = 0;
  int stride = 0;
  double left = 0.0;
  double top = 0.0;
  double displayWidth = 0.0;
  double displayHeight = 0.0;
};

/** One LTR text line laid out by the platform in canonical page coordinates. */
struct PdfiumExportTextLine final {
  std::u16string text;
  double left = 0.0;
  double baselineFromTop = 0.0;
  double fontSize = 0.0;
  std::uint32_t color = 0xFF000000u;
  bool rightToLeft = false;
};

struct PdfiumSignedExportPage final {
  PdfiumPageMetadata expectedGeometry;
  std::optional<PdfiumInkBitmap> ink;
  std::vector<PdfiumExportTextLine> textLines;
};

struct PdfiumSignedExportResult final {
  std::vector<std::uint8_t> bytes;
  PdfiumError error;

  bool ok() const { return !bytes.empty() && error.ok(); }
  explicit operator bool() const { return ok(); }
};

/** Writes and reopens a detached signed candidate through PDFium. */
class PdfiumSignedDocumentExporter final {
 public:
  PdfiumSignedDocumentExporter() = delete;

  static PdfiumSignedExportResult write(
      const std::vector<std::uint8_t>& sourceBytes,
      const std::vector<PdfiumSignedExportPage>& pages);
};

}  // namespace margelo::nitro::inksignpdf::pdfium
