#pragma once

#include "pdfium-adapter/PdfiumDocumentSession.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

enum class PdfiumPageAssemblyOperation : std::uint8_t {
  Append,
  Remove,
  Move,
};

enum class PdfiumAppendInputType : std::uint8_t {
  Pdf,
  Image,
};

struct PdfiumImagePlacement final {
  double a = 1.0;
  double b = 0.0;
  double c = 0.0;
  double d = 1.0;
  double e = 0.0;
  double f = 0.0;
};

/** One native-owned source staged for an append command. */
struct PdfiumAppendInput final {
  PdfiumAppendInputType type = PdfiumAppendInputType::Pdf;
  std::vector<std::uint8_t> bytes;
  double pageWidth = 0.0;
  double pageHeight = 0.0;
  PdfiumImagePlacement placement;
};

/** Exactly one structural operation to apply to one working PDF. */
struct PdfiumPageAssemblyCommand final {
  PdfiumPageAssemblyOperation operation = PdfiumPageAssemblyOperation::Append;
  std::vector<PdfiumAppendInput> appendInputs;
  std::size_t pageIndex = 0;
  std::size_t destinationIndex = 0;
};

struct PdfiumPageAssemblyResult final {
  std::string outputPath;
  std::vector<PdfiumPageMetadata> pages;
  PdfiumError error;

  bool ok() const { return !outputPath.empty() && error.ok(); }
  explicit operator bool() const { return ok(); }
};

/**
 * A synchronous, one-shot PDF page-structure mutation.
 *
 * The caller owns the serial worker on which this method runs. The adapter
 * owns all copied command bytes until PDFium closes the corresponding handles,
 * writes a validated candidate to scratchPath, and returns detached metadata.
 */
class PdfiumPageAssembler final {
 public:
  PdfiumPageAssembler() = delete;

  static PdfiumPageAssemblyResult assemble(
      std::vector<std::uint8_t> inputBytes,
      PdfiumPageAssemblyCommand command,
      std::string scratchPath);
};

}  // namespace margelo::nitro::inksignpdf::pdfium
