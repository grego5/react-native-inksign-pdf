#include "pdfium-adapter/PdfiumPageAssembler.hpp"
#include "pdfium-adapter/PdfiumLibraryInternal.hpp"

#include <fpdf_edit.h>
#include <fpdf_ppo.h>
#include <fpdf_save.h>
#include <fpdfview.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

class ScopedDocument final {
 public:
  explicit ScopedDocument(FPDF_DOCUMENT document) : document_(document) {}
  ScopedDocument(const ScopedDocument&) = delete;
  ScopedDocument& operator=(const ScopedDocument&) = delete;
  ~ScopedDocument() {
    if (document_ != nullptr) FPDF_CloseDocument(document_);
  }

  FPDF_DOCUMENT get() const { return document_; }

 private:
  FPDF_DOCUMENT document_ = nullptr;
};

class ScopedPage final {
 public:
  explicit ScopedPage(FPDF_PAGE page) : page_(page) {}
  ScopedPage(const ScopedPage&) = delete;
  ScopedPage& operator=(const ScopedPage&) = delete;
  ~ScopedPage() {
    if (page_ != nullptr) FPDF_ClosePage(page_);
  }

  FPDF_PAGE get() const { return page_; }

 private:
  FPDF_PAGE page_ = nullptr;
};

struct VectorFileWriter final {
  FPDF_FILEWRITE fileWrite{1, &writeBlock};
  std::vector<std::uint8_t> bytes;

  static int writeBlock(FPDF_FILEWRITE* fileWrite,
                        const void* data,
                        unsigned long size) {
    auto* writer = reinterpret_cast<VectorFileWriter*>(fileWrite);
    if (size == 0) return 1;
    if (data == nullptr) return 0;
    try {
      const auto* begin = static_cast<const std::uint8_t*>(data);
      writer->bytes.insert(writer->bytes.end(), begin, begin + size);
      return 1;
    } catch (...) {
      return 0;
    }
  }
};

struct ImageFileAccess final {
  FPDF_FILEACCESS fileAccess{};
  const std::vector<std::uint8_t>* bytes = nullptr;

  static int getBlock(void* parameter,
                      unsigned long position,
                      unsigned char* buffer,
                      unsigned long size) {
    const auto* access = static_cast<const ImageFileAccess*>(parameter);
    if (access == nullptr || access->bytes == nullptr ||
        position > access->bytes->size() ||
        size > access->bytes->size() - position) {
      return 0;
    }
    std::memcpy(buffer, access->bytes->data() + position, size);
    return 1;
  }
};

bool finite(double value) {
  return std::isfinite(value);
}

bool validPlacement(const PdfiumImagePlacement& placement) {
  const double determinant =
      placement.a * placement.d - placement.b * placement.c;
  return finite(placement.a) && finite(placement.b) && finite(placement.c) &&
      finite(placement.d) && finite(placement.e) && finite(placement.f) &&
      finite(determinant) && std::abs(determinant) > 1e-12;
}

PdfiumError invalidInput(std::string message) {
  return {PdfiumErrorCode::InvalidInput, std::move(message)};
}

PdfiumError invalidCommand(std::string message) {
  return {PdfiumErrorCode::InvalidAssemblyCommand, std::move(message)};
}

PdfiumError loadDocument(const std::vector<std::uint8_t>& bytes,
                         FPDF_DOCUMENT& document,
                         PdfiumErrorCode errorCode,
                         const char* label) {
  if (bytes.empty()) return invalidInput(std::string(label) + " is empty");
  if (bytes.size() >
      static_cast<std::size_t>((std::numeric_limits<int>::max)())) {
    return invalidInput(std::string(label) + " exceeds the supported byte size");
  }

  document = FPDF_LoadMemDocument(
      bytes.data(), static_cast<int>(bytes.size()), nullptr);
  if (document == nullptr) {
    return {errorCode,
            std::string("PDFium could not open ") + label + " (PDFium error " +
                std::to_string(FPDF_GetLastError()) + ")"};
  }
  const int count = FPDF_GetPageCount(document);
  if (count <= 0) {
    FPDF_CloseDocument(document);
    document = nullptr;
    return {errorCode, std::string(label) + " contains no pages"};
  }
  if (FPDF_GetSecurityHandlerRevision(document) >= 0) {
    FPDF_CloseDocument(document);
    document = nullptr;
    return {errorCode, std::string(label) + " is encrypted"};
  }
  return {};
}

PdfiumError inspectPages(FPDF_DOCUMENT document,
                         std::vector<PdfiumPageMetadata>& pages) {
  const int count = FPDF_GetPageCount(document);
  if (count <= 0) {
    return {PdfiumErrorCode::ValidationFailed,
            "PDFium candidate contains no pages"};
  }

  pages.clear();
  pages.reserve(static_cast<std::size_t>(count));
  for (int index = 0; index < count; ++index) {
    ScopedPage page(FPDF_LoadPage(document, index));
    if (page.get() == nullptr) {
      return {PdfiumErrorCode::ValidationFailed,
              "PDFium candidate page could not be opened"};
    }
    const double width = FPDF_GetPageWidth(page.get());
    const double height = FPDF_GetPageHeight(page.get());
    const int rotation = FPDFPage_GetRotation(page.get());
    if (!(width > 0.0) || !(height > 0.0) || !finite(width) ||
        !finite(height) || rotation < 0 || rotation > 3) {
      return {PdfiumErrorCode::ValidationFailed,
              "PDFium candidate contains invalid page metadata"};
    }
    pages.push_back({static_cast<std::size_t>(index), width, height, rotation});
  }
  return {};
}

void reindex(std::vector<PdfiumPageMetadata>& pages) {
  for (std::size_t index = 0; index < pages.size(); ++index) {
    pages[index].pageIndex = index;
  }
}

bool sameMetadata(const PdfiumPageMetadata& expected,
                  const PdfiumPageMetadata& actual) {
  constexpr double kDimensionTolerance = 1e-6;
  return expected.rotation == actual.rotation &&
      std::abs(expected.width - actual.width) <= kDimensionTolerance &&
      std::abs(expected.height - actual.height) <= kDimensionTolerance;
}

PdfiumError appendImage(FPDF_DOCUMENT document,
                        std::size_t pageIndex,
                        const PdfiumAppendInput& input) {
  if (input.bytes.empty() ||
      input.bytes.size() >
          static_cast<std::size_t>((std::numeric_limits<unsigned long>::max)()) ||
      !(input.pageWidth > 0.0) || !(input.pageHeight > 0.0) ||
      !finite(input.pageWidth) || !finite(input.pageHeight) ||
      !validPlacement(input.placement)) {
    return invalidInput("image page input is invalid");
  }

  ScopedPage page(FPDFPage_New(document, static_cast<int>(pageIndex),
                               input.pageWidth, input.pageHeight));
  if (page.get() == nullptr) {
    return {PdfiumErrorCode::MutationFailed,
            "FPDFPage_New failed for image page"};
  }

  FPDF_PAGEOBJECT image = FPDFPageObj_NewImageObj(document);
  if (image == nullptr) {
    return {PdfiumErrorCode::MutationFailed,
            "FPDFPageObj_NewImageObj failed"};
  }

  ImageFileAccess access;
  access.fileAccess.m_FileLen = static_cast<unsigned long>(input.bytes.size());
  access.fileAccess.m_GetBlock = &ImageFileAccess::getBlock;
  access.fileAccess.m_Param = &access;
  FPDF_PAGE pages[] = {page.get()};
  if (!FPDFImageObj_LoadJpegFileInline(
          pages, 1, image, &access.fileAccess)) {
    FPDFPageObj_Destroy(image);
    return {PdfiumErrorCode::MutationFailed,
            "FPDFImageObj_LoadJpegFileInline failed"};
  }

  const auto& placement = input.placement;
  if (!FPDFImageObj_SetMatrix(image, placement.a, placement.b, placement.c,
                              placement.d, placement.e, placement.f)) {
    FPDFPageObj_Destroy(image);
    return {PdfiumErrorCode::MutationFailed,
            "FPDFImageObj_SetMatrix failed"};
  }

  // FPDFPage_InsertObject takes ownership on both success and failure.
  if (!FPDFPage_InsertObject(page.get(), image)) {
    return {PdfiumErrorCode::MutationFailed,
            "FPDFPage_InsertObject failed"};
  }
  if (!FPDFPage_GenerateContent(page.get())) {
    return {PdfiumErrorCode::MutationFailed,
            "FPDFPage_GenerateContent failed"};
  }
  return {};
}

int pdfiumDestinationIndex(std::size_t finalIndex) {
  // PDFium inserts at the destination index after removing the moved pages.
  // For one page this is exactly the caller-visible final zero-based index.
  return static_cast<int>(finalIndex);
}

PdfiumError writeScratch(const std::string& path,
                         const std::vector<std::uint8_t>& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output.is_open()) {
    return {PdfiumErrorCode::SaveFailed,
            "Unable to open PDFium assembly scratch path"};
  }
  output.write(reinterpret_cast<const char*>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  if (!output.good()) {
    return {PdfiumErrorCode::SaveFailed,
            "Unable to write PDFium assembly scratch path"};
  }
  output.close();
  if (!output.good()) {
    return {PdfiumErrorCode::SaveFailed,
            "Unable to close PDFium assembly scratch path"};
  }
  return {};
}

}  // namespace

PdfiumPageAssemblyResult PdfiumPageAssembler::assemble(
    std::vector<std::uint8_t> inputBytes,
    PdfiumPageAssemblyCommand command,
    std::string scratchPath) {
  PdfiumPageAssemblyResult result;
  if (inputBytes.empty() || scratchPath.empty()) {
    result.error = invalidInput("assembly input and scratch path are required");
    return result;
  }

  std::vector<PdfiumPageMetadata> expectedPages;
  VectorFileWriter writer;
  PdfiumError operationError;

  PdfiumError libraryError;
  auto library = PdfiumLibrary::acquire(libraryError);
  if (!library) {
    result.error = libraryError.ok()
        ? PdfiumError{PdfiumErrorCode::LibraryInitializationFailed,
                      "Unable to initialize PDFium for page assembly"}
        : libraryError;
    return result;
  }

  {
    auto& state = pdfiumLibraryState();
    std::lock_guard apiLock(state.apiMutex);

    FPDF_DOCUMENT destination = nullptr;
    operationError = loadDocument(inputBytes, destination,
                                  PdfiumErrorCode::DocumentOpenFailed,
                                  "working PDF");
    ScopedDocument destinationScope(destination);
    if (operationError) {
      operationError = inspectPages(destination, expectedPages);
    }

    if (operationError &&
        command.operation == PdfiumPageAssemblyOperation::Append &&
        command.appendInputs.empty()) {
      operationError = invalidCommand("append command contains no inputs");
    }
    if (operationError &&
        command.operation != PdfiumPageAssemblyOperation::Append &&
        !command.appendInputs.empty()) {
      operationError = invalidCommand(
          "non-append command contains append inputs");
    }
    if (operationError &&
        command.operation != PdfiumPageAssemblyOperation::Append &&
        command.operation != PdfiumPageAssemblyOperation::Remove &&
        command.operation != PdfiumPageAssemblyOperation::Move) {
      operationError = invalidCommand("assembly operation is invalid");
    }
    if (operationError && command.operation == PdfiumPageAssemblyOperation::Remove &&
        expectedPages.size() <= 1) {
      operationError = {PdfiumErrorCode::LastPageRequired,
                        "The working PDF must retain one page"};
    }
    if (operationError && command.operation == PdfiumPageAssemblyOperation::Remove &&
        command.pageIndex >= expectedPages.size()) {
      operationError = {PdfiumErrorCode::InvalidPageIndex,
                        "Remove page index is outside the working PDF"};
    }
    if (operationError && command.operation == PdfiumPageAssemblyOperation::Move &&
        (command.pageIndex >= expectedPages.size() ||
         command.destinationIndex >= expectedPages.size())) {
      operationError = {PdfiumErrorCode::InvalidPageIndex,
                        "Move page index is outside the working PDF"};
    }

    if (operationError &&
        command.operation == PdfiumPageAssemblyOperation::Append) {
      for (const auto& input : command.appendInputs) {
        if (input.type == PdfiumAppendInputType::Pdf) {
          FPDF_DOCUMENT source = nullptr;
          operationError = loadDocument(
              input.bytes, source, PdfiumErrorCode::SourceDocumentOpenFailed,
              "source PDF");
          if (!operationError) break;
          ScopedDocument sourceScope(source);
          std::vector<PdfiumPageMetadata> sourcePages;
          operationError = inspectPages(source, sourcePages);
          if (!operationError) break;
          if (expectedPages.size() >
              static_cast<std::size_t>((std::numeric_limits<int>::max)())) {
            operationError = invalidInput("assembled PDF has too many pages");
            break;
          }
          if (!FPDF_ImportPagesByIndex(
                  destination, source, nullptr, 0,
                  static_cast<int>(expectedPages.size()))) {
            operationError = {PdfiumErrorCode::MutationFailed,
                              "FPDF_ImportPagesByIndex failed"};
            break;
          }
          for (auto page : sourcePages) {
            page.pageIndex = expectedPages.size();
            expectedPages.push_back(page);
          }
          continue;
        }
        if (input.type != PdfiumAppendInputType::Image) {
          operationError = invalidCommand("append input type is invalid");
          break;
        }
        if (expectedPages.size() >
            static_cast<std::size_t>((std::numeric_limits<int>::max)())) {
          operationError = invalidInput("assembled PDF has too many pages");
          break;
        }
        operationError = appendImage(destination, expectedPages.size(), input);
        if (!operationError) break;
        expectedPages.push_back(
            {expectedPages.size(), input.pageWidth, input.pageHeight, 0});
      }
    }

    if (operationError &&
        command.operation == PdfiumPageAssemblyOperation::Remove) {
      FPDFPage_Delete(destination, static_cast<int>(command.pageIndex));
      expectedPages.erase(expectedPages.begin() + command.pageIndex);
      reindex(expectedPages);
    }

    if (operationError && command.operation == PdfiumPageAssemblyOperation::Move &&
        command.pageIndex != command.destinationIndex) {
      const int sourceIndex = static_cast<int>(command.pageIndex);
      const int destinationIndex =
          pdfiumDestinationIndex(command.destinationIndex);
      if (!FPDF_MovePages(destination, &sourceIndex, 1, destinationIndex)) {
        operationError = {PdfiumErrorCode::MutationFailed,
                          "FPDF_MovePages failed"};
      } else {
        auto moved = expectedPages[command.pageIndex];
        expectedPages.erase(expectedPages.begin() + command.pageIndex);
        expectedPages.insert(expectedPages.begin() + command.destinationIndex,
                             moved);
        reindex(expectedPages);
      }
    }

    if (operationError && !FPDF_SaveAsCopy(
                             destination, &writer.fileWrite,
                             FPDF_NO_INCREMENTAL)) {
      operationError = {PdfiumErrorCode::SaveFailed,
                        "FPDF_SaveAsCopy failed"};
    }
  }

  if (!operationError) {
    result.error = operationError;
    return result;
  }

  auto candidate = PdfiumDocumentSession::open(writer.bytes);
  if (!candidate) {
    result.error = {PdfiumErrorCode::ValidationFailed,
                    "Saved PDFium assembly candidate could not be reopened"};
    return result;
  }
  std::vector<PdfiumPageMetadata> actualPages;
  for (std::size_t index = 0; index < candidate.session->pageCount(); ++index) {
    PdfiumPageMetadata metadata;
    const auto error = candidate.session->inspectPage(index, metadata);
    if (!error) {
      result.error = {PdfiumErrorCode::ValidationFailed,
                      "Saved PDFium assembly candidate metadata is invalid"};
      return result;
    }
    actualPages.push_back(metadata);
  }
  if (actualPages.size() != expectedPages.size()) {
    result.error = {PdfiumErrorCode::ValidationFailed,
                    "Saved PDFium assembly page count does not match"};
    return result;
  }
  for (std::size_t index = 0; index < actualPages.size(); ++index) {
    if (!sameMetadata(expectedPages[index], actualPages[index])) {
      result.error = {PdfiumErrorCode::ValidationFailed,
                      "Saved PDFium assembly page order does not match"};
      return result;
    }
  }
  candidate.session->close();

  const auto writeError = writeScratch(scratchPath, writer.bytes);
  if (!writeError) {
    result.error = writeError;
    return result;
  }
  result.outputPath = std::move(scratchPath);
  result.pages = std::move(actualPages);
  result.error = {};
  return result;
}

}  // namespace margelo::nitro::inksignpdf::pdfium
