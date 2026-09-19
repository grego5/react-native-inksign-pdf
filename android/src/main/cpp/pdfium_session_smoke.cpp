#include "pdfium/PdfiumDocumentSession.hpp"

#include <cstdint>
#include <cmath>
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

std::vector<std::uint8_t> textPdf(
    const std::string& mediaBox,
    const std::string& content) {
  const std::string header = "%PDF-1.4\n";
  const std::string object1 =
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n";
  const std::string object2 =
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n";
  const std::string object3 =
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox " + mediaBox +
      "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>\nendobj\n";
  const std::string object4 =
      "4 0 obj\n<< /Length " + std::to_string(content.size()) +
      " >>\nstream\n" + content + "endstream\nendobj\n";
  const std::string object5 =
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\n"
      "endobj\n";

  std::string pdf = header;
  const std::size_t offset1 = pdf.size();
  pdf += object1;
  const std::size_t offset2 = pdf.size();
  pdf += object2;
  const std::size_t offset3 = pdf.size();
  pdf += object3;
  const std::size_t offset4 = pdf.size();
  pdf += object4;
  const std::size_t offset5 = pdf.size();
  pdf += object5;
  const std::size_t xrefOffset = pdf.size();
  pdf += "xref\n0 6\n"
         "0000000000 65535 f \n";
  char entry[32];
  for (const std::size_t offset :
       {offset1, offset2, offset3, offset4, offset5}) {
    const int written =
        snprintf(entry, sizeof(entry), "%010zu 00000 n \n", offset);
    pdf.append(entry, static_cast<std::size_t>(written));
  }
  pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n";
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

  auto textSession = PdfiumDocumentSession::open(
      textPdf("[0 0 100 100]",
              "BT /F1 20 Tf 1 0 0 1 10 60 Tm (AB) Tj ET\n"));
  if (!textSession) return false;
  const auto extracted = textSession.session->extractPage(0);
  if (!extracted || extracted.page->pageBounds().right != 100.0 ||
      extracted.page->pageBounds().bottom != 100.0 ||
      extracted.page->characters().size() < 2) {
    return false;
  }
  const auto& firstCharacter = extracted.page->characters().front();
  const auto& secondCharacter = extracted.page->characters()[1];
  if (firstCharacter.unicode != 'A' || firstCharacter.sourceIndex != 0 ||
      firstCharacter.origin.x < 9.0 || firstCharacter.origin.x > 11.0 ||
      firstCharacter.origin.y < 39.0 || firstCharacter.origin.y > 41.0 ||
      firstCharacter.fontSize < 19.0 || firstCharacter.fontSize > 21.0 ||
      secondCharacter.unicode != 'B' ||
      secondCharacter.origin.x <= firstCharacter.origin.x) {
    return false;
  }
  if (textSession.session->extractPage(1).error.code !=
      PdfiumErrorCode::InvalidPageIndex) {
    return false;
  }
  if (!textSession.session->close()) return false;

  auto transformedSession = PdfiumDocumentSession::open(
      textPdf("[10 20 110 120]",
              "BT /F1 20 Tf 0 1 -1 0 40 70 Tm (AB) Tj ET\n"));
  if (!transformedSession) return false;
  const auto transformed = transformedSession.session->extractPage(0);
  if (!transformed || transformed.page->characters().size() != 2) {
    return false;
  }
  const auto& rotatedCharacter = transformed.page->characters().front();
  const auto& nextRotatedCharacter = transformed.page->characters()[1];
  const auto nearlyEqual = [](double first, double second) {
    return std::abs(first - second) <= 0.01;
  };
  if (!nearlyEqual(rotatedCharacter.origin.x, 30.0) ||
      !nearlyEqual(rotatedCharacter.origin.y, 50.0) ||
      !nearlyEqual(rotatedCharacter.matrix.a, 0.0) ||
      !nearlyEqual(rotatedCharacter.matrix.b, -1.0) ||
      !nearlyEqual(rotatedCharacter.matrix.c, -1.0) ||
      !nearlyEqual(rotatedCharacter.matrix.d, 0.0) ||
      !nearlyEqual(rotatedCharacter.matrix.e, rotatedCharacter.origin.x) ||
      !nearlyEqual(rotatedCharacter.matrix.f, rotatedCharacter.origin.y) ||
      nextRotatedCharacter.unicode != 'B' ||
      !nearlyEqual(nextRotatedCharacter.matrix.e, rotatedCharacter.matrix.e) ||
      !nearlyEqual(nextRotatedCharacter.matrix.f, rotatedCharacter.matrix.f) ||
      nextRotatedCharacter.origin.y >= rotatedCharacter.origin.y ||
      rotatedCharacter.bounds.left < 0.0 ||
      rotatedCharacter.bounds.top < 0.0 ||
      rotatedCharacter.bounds.right > 100.0 ||
      rotatedCharacter.bounds.bottom > 100.0) {
    return false;
  }
  if (!transformedSession.session->close()) return false;

  auto second = PdfiumDocumentSession::open(minimalPdf());
  if (!second || second.session->pageCount() != 1) return false;
  if (!second.session->close() || !first.session->close()) return false;
  return true;
}
