#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include "pdfium-adapter/PdfiumPageAssembler.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <span>
#include <string>
#include <utility>
#include <vector>

using margelo::nitro::inksignpdf::pdfium::PdfiumDocumentSession;
using margelo::nitro::inksignpdf::pdfium::PdfiumErrorCode;
using margelo::nitro::inksignpdf::pdfium::PdfiumAppendInput;
using margelo::nitro::inksignpdf::pdfium::PdfiumAppendInputType;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssembler;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssemblyCommand;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssemblyOperation;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageMetadata;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageRenderRequest;

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

std::vector<std::uint8_t> multiPagePdf(
    const std::vector<std::pair<int, int>>& sizes) {
  std::vector<std::string> objects;
  objects.emplace_back("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

  std::string kids = "[";
  for (std::size_t index = 0; index < sizes.size(); ++index) {
    kids += std::to_string(3 + index) + " 0 R ";
  }
  kids += "]";
  objects.push_back("2 0 obj\n<< /Type /Pages /Kids " + kids +
                    " /Count " + std::to_string(sizes.size()) +
                    " >>\nendobj\n");
  for (std::size_t index = 0; index < sizes.size(); ++index) {
    const auto [width, height] = sizes[index];
    const std::size_t contentObject = 3 + sizes.size() + index;
    objects.push_back(
        std::to_string(3 + index) +
        " 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " +
        std::to_string(width) + " " + std::to_string(height) +
        "] /Contents " + std::to_string(contentObject) +
        " 0 R >>\nendobj\n");
  }
  for (std::size_t index = 0; index < sizes.size(); ++index) {
    objects.push_back(std::to_string(3 + sizes.size() + index) +
                      " 0 obj\n<< /Length 0 >>\nstream\n\nendstream\n"
                      "endobj\n");
  }

  std::string pdf = "%PDF-1.4\n";
  std::vector<std::size_t> offsets;
  offsets.reserve(objects.size());
  for (const auto& object : objects) {
    offsets.push_back(pdf.size());
    pdf += object;
  }
  const std::size_t xrefOffset = pdf.size();
  pdf += "xref\n0 " + std::to_string(objects.size() + 1) +
         "\n0000000000 65535 f \n";
  char entry[32];
  for (const std::size_t offset : offsets) {
    const int written =
        snprintf(entry, sizeof(entry), "%010zu 00000 n \n", offset);
    pdf.append(entry, static_cast<std::size_t>(written));
  }
  pdf += "trailer\n<< /Size " + std::to_string(objects.size() + 1) +
         " /Root 1 0 R >>\nstartxref\n";
  pdf += std::to_string(xrefOffset);
  pdf += "\n%%EOF\n";
  return {pdf.begin(), pdf.end()};
}

std::vector<std::uint8_t> readFile(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  return {std::istreambuf_iterator<char>(input),
          std::istreambuf_iterator<char>()};
}

bool matchesSizes(const std::vector<PdfiumPageMetadata>& pages,
                  const std::vector<std::pair<double, double>>& sizes) {
  if (pages.size() != sizes.size()) return false;
  for (std::size_t index = 0; index < pages.size(); ++index) {
    if (pages[index].width != sizes[index].first ||
        pages[index].height != sizes[index].second ||
        pages[index].rotation != 0) {
      return false;
    }
  }
  return true;
}

}  // namespace

extern "C" bool ReactNativeInkSignPdfPdfiumSessionLifecycleSmoke() {
  auto invalid = PdfiumDocumentSession::open({});
  if (invalid || invalid.error.code != PdfiumErrorCode::InvalidInput) return false;

  auto first = PdfiumDocumentSession::open(minimalPdf());
  if (!first || first.session->pageCount() != 1) return false;

  PdfiumPageMetadata metadata;
  if (!first.session->inspectPage(0, metadata) || metadata.width != 100.0 ||
      metadata.height != 100.0) {
    return false;
  }
  if (first.session->inspectPage(1, metadata).code !=
      PdfiumErrorCode::InvalidPageIndex) {
    return false;
  }

  auto renderSession = PdfiumDocumentSession::open(
      textPdf("[0 0 100 100]", "0 0 0 rg 10 5 30 20 re f\n"));
  if (!renderSession) return false;

  std::vector<std::uint8_t> pixels(404 * 100, 0xA5);
  PdfiumPageRenderRequest renderRequest;
  renderRequest.pageIndex = 0;
  renderRequest.width = 100;
  renderRequest.height = 100;
  renderRequest.stride = 404;
  renderRequest.pageToDevice = {1.0, 0.0, 0.0, 1.0, 0.0, 0.0};
  renderRequest.clip = {0.0, 0.0, 100.0, 100.0};
  renderRequest.bgra = std::span<std::uint8_t>(pixels);
  const auto fullRenderError = renderSession.session->renderPage(renderRequest);
  if (!fullRenderError.ok() ||
      pixels[15 * renderRequest.stride + 20 * 4] != 0xFF ||
      pixels[85 * renderRequest.stride + 20 * 4] >= 0x80 ||
      pixels[45 * renderRequest.stride + 100 * 4] != 0xA5) {
    return false;
  }

  std::fill(pixels.begin(), pixels.end(), 0xA5);
  renderRequest.clip = {0.0, 50.0, 50.0, 100.0};
  const auto clippedRenderError = renderSession.session->renderPage(renderRequest);
  if (!clippedRenderError.ok() ||
      pixels[15 * renderRequest.stride + 20 * 4] != 0xFF ||
      pixels[85 * renderRequest.stride + 20 * 4] >= 0x80) {
    return false;
  }

  std::vector<std::uint8_t> undersized(16, 0x5A);
  renderRequest.clip = {0.0, 0.0, 100.0, 100.0};
  renderRequest.bgra = std::span<std::uint8_t>(undersized);
  const auto undersizedError = renderSession.session->renderPage(renderRequest);
  if (undersizedError.code != PdfiumErrorCode::InvalidInput ||
      !std::all_of(undersized.begin(), undersized.end(),
                   [](std::uint8_t value) { return value == 0x5A; })) {
    return false;
  }
  if (!renderSession.session->close()) return false;

  auto second = PdfiumDocumentSession::open(minimalPdf());
  if (!second || second.session->pageCount() != 1) return false;
  if (!second.session->close() || !first.session->close()) return false;
  return true;
}

extern "C" bool ReactNativeInkSignPdfPdfiumAssemblySmoke(
    const char* scratchPath,
    const std::uint8_t* jpegBytes,
    std::size_t jpegSize) {
  if (scratchPath == nullptr || jpegBytes == nullptr || jpegSize == 0) {
    return false;
  }
  const std::string appendPath = std::string(scratchPath) + ".append.pdf";
  const std::string movePath = std::string(scratchPath) + ".move.pdf";
  const std::string backwardPath = std::string(scratchPath) + ".backward.pdf";
  const std::string removePath = std::string(scratchPath) + ".remove.pdf";
  const std::string invalidPath = std::string(scratchPath) + ".invalid.pdf";
  const std::string solePath = std::string(scratchPath) + ".sole.pdf";
  const std::string firstRemovePath =
      std::string(scratchPath) + ".first-remove.pdf";
  const std::string lastRemovePath =
      std::string(scratchPath) + ".last-remove.pdf";
  for (const auto& path :
       {appendPath, movePath, backwardPath, removePath, invalidPath, solePath,
        firstRemovePath, lastRemovePath}) {
    std::remove(path.c_str());
  }

  PdfiumAppendInput source;
  source.type = PdfiumAppendInputType::Pdf;
  source.bytes = multiPagePdf({{200, 100}, {300, 100}});
  PdfiumAppendInput image;
  image.type = PdfiumAppendInputType::Image;
  image.bytes.assign(jpegBytes, jpegBytes + jpegSize);
  image.pageWidth = 80.0;
  image.pageHeight = 90.0;
  image.placement = {40.0, 0.0, 0.0, 20.0, 10.0, 15.0};

  PdfiumPageAssemblyCommand append;
  append.operation = PdfiumPageAssemblyOperation::Append;
  append.appendInputs.push_back(std::move(source));
  append.appendInputs.push_back(std::move(image));
  const auto appended = PdfiumPageAssembler::assemble(
      multiPagePdf({{100, 100}, {110, 100}, {120, 100}}),
      std::move(append), appendPath);
  if (!appended ||
      !matchesSizes(appended.pages,
                    {{100, 100}, {110, 100}, {120, 100}, {200, 100},
                     {300, 100}, {80, 90}})) {
    return false;
  }
  const auto appendedBytes = readFile(appendPath);
  if (appendedBytes.empty()) return false;

  PdfiumPageAssemblyCommand move;
  move.operation = PdfiumPageAssemblyOperation::Move;
  move.pageIndex = 0;
  move.destinationIndex = 5;
  const auto moved = PdfiumPageAssembler::assemble(
      appendedBytes, std::move(move), movePath);
  if (!moved ||
      !matchesSizes(moved.pages,
                    {{110, 100}, {120, 100}, {200, 100}, {300, 100},
                     {80, 90}, {100, 100}})) {
    return false;
  }

  PdfiumPageAssemblyCommand backward;
  backward.operation = PdfiumPageAssemblyOperation::Move;
  backward.pageIndex = 5;
  backward.destinationIndex = 1;
  const auto movedBackward = PdfiumPageAssembler::assemble(
      readFile(movePath), std::move(backward), backwardPath);
  if (!movedBackward ||
      !matchesSizes(movedBackward.pages,
                    {{110, 100}, {100, 100}, {120, 100}, {200, 100},
                     {300, 100}, {80, 90}})) {
    return false;
  }

  PdfiumPageAssemblyCommand sameIndex;
  sameIndex.operation = PdfiumPageAssemblyOperation::Move;
  sameIndex.pageIndex = 2;
  sameIndex.destinationIndex = 2;
  const auto same = PdfiumPageAssembler::assemble(
      readFile(backwardPath), std::move(sameIndex), removePath);
  if (!same ||
      !matchesSizes(same.pages,
                    {{110, 100}, {100, 100}, {120, 100}, {200, 100},
                     {300, 100}, {80, 90}})) {
    return false;
  }

  PdfiumPageAssemblyCommand removeMiddle;
  removeMiddle.operation = PdfiumPageAssemblyOperation::Remove;
  removeMiddle.pageIndex = 2;
  const auto removed = PdfiumPageAssembler::assemble(
      readFile(removePath), std::move(removeMiddle), invalidPath);
  if (!removed ||
      !matchesSizes(removed.pages, {{110, 100}, {100, 100}, {200, 100},
                                    {300, 100}, {80, 90}})) {
    return false;
  }

  PdfiumPageAssemblyCommand removeFirst;
  removeFirst.operation = PdfiumPageAssemblyOperation::Remove;
  removeFirst.pageIndex = 0;
  const auto removedFirst = PdfiumPageAssembler::assemble(
      readFile(invalidPath), std::move(removeFirst), firstRemovePath);
  if (!removedFirst ||
      !matchesSizes(removedFirst.pages,
                    {{100, 100}, {200, 100}, {300, 100}, {80, 90}})) {
    return false;
  }

  PdfiumPageAssemblyCommand removeLast;
  removeLast.operation = PdfiumPageAssemblyOperation::Remove;
  removeLast.pageIndex = 3;
  const auto removedLast = PdfiumPageAssembler::assemble(
      readFile(firstRemovePath), std::move(removeLast), lastRemovePath);
  if (!removedLast ||
      !matchesSizes(removedLast.pages,
                    {{100, 100}, {200, 100}, {300, 100}})) {
    return false;
  }

  PdfiumPageAssemblyCommand invalidMove;
  invalidMove.operation = PdfiumPageAssemblyOperation::Move;
  invalidMove.pageIndex = 0;
  invalidMove.destinationIndex = 99;
  const auto unchangedInput = readFile(invalidPath);
  const auto failed = PdfiumPageAssembler::assemble(
      readFile(invalidPath), std::move(invalidMove), solePath);
  if (failed || !readFile(solePath).empty() ||
      readFile(invalidPath) != unchangedInput) {
    return false;
  }

  PdfiumPageAssemblyCommand removeOnly;
  removeOnly.operation = PdfiumPageAssemblyOperation::Remove;
  removeOnly.pageIndex = 0;
  const auto only = PdfiumPageAssembler::assemble(
      multiPagePdf({{50, 50}}), std::move(removeOnly), solePath);
  if (only || only.error.code != PdfiumErrorCode::LastPageRequired ||
      !readFile(solePath).empty()) {
    return false;
  }

  for (const auto& path :
       {appendPath, movePath, backwardPath, removePath, invalidPath, solePath,
        firstRemovePath, lastRemovePath}) {
    std::remove(path.c_str());
  }
  return true;
}
