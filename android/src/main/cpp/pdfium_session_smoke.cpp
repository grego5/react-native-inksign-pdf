#include "pdfium/PdfiumDocumentSession.hpp"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using margelo::nitro::inksignpdf::pdfium::PdfiumDocumentSession;
using margelo::nitro::inksignpdf::pdfium::PdfiumErrorCode;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageMetadata;

namespace {

std::vector<std::uint8_t> minimalPdf() {
  const std::string header = "%PDF-1.4\n";
  const std::string object1 =
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n";
  const std::string object2 =
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n";
  const std::string object3 =
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] "
      "/Contents 4 0 R >>\nendobj\n";
  const std::string object4 =
      "4 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n";

  std::string pdf = header;
  const std::size_t offset1 = pdf.size();
  pdf += object1;
  const std::size_t offset2 = pdf.size();
  pdf += object2;
  const std::size_t offset3 = pdf.size();
  pdf += object3;
  const std::size_t offset4 = pdf.size();
  pdf += object4;
  const std::size_t xrefOffset = pdf.size();
  pdf += "xref\n0 5\n"
         "0000000000 65535 f \n";
  char entry[32];
  for (const std::size_t offset : {offset1, offset2, offset3, offset4}) {
    const int written = snprintf(entry, sizeof(entry), "%010zu 00000 n \n", offset);
    pdf.append(entry, static_cast<std::size_t>(written));
  }
  pdf += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n";
  pdf += std::to_string(xrefOffset);
  pdf += "\n%%EOF\n";
  return {pdf.begin(), pdf.end()};
}

}  // namespace

extern "C" bool ReactNativeInkSignPdfPdfiumSessionLifecycleSmoke() {
  auto invalid = PdfiumDocumentSession::open({});
  if (invalid || invalid.error.code != PdfiumErrorCode::InvalidInput) return false;

  auto first = PdfiumDocumentSession::open(minimalPdf());
  if (!first || first.session->pageCount() != 1) return false;

  PdfiumPageMetadata metadata;
  if (!first.session->inspectPage(0, metadata) || metadata.width != 100.0 ||
      metadata.height != 100.0 || metadata.textCharacterCount != 0) {
    return false;
  }
  if (first.session->inspectPage(1, metadata).code !=
      PdfiumErrorCode::InvalidPageIndex) {
    return false;
  }

  auto second = PdfiumDocumentSession::open(minimalPdf());
  if (!second || second.session->pageCount() != 1) return false;
  if (!second.session->close() || !first.session->close()) return false;
  return true;
}
