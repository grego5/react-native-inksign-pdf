#include "pdfium-adapter/PdfiumSignedDocumentExporter.hpp"
#include "pdfium-adapter/PdfiumLibraryInternal.hpp"

#include <fpdf_edit.h>
#include <fpdf_save.h>
#include <fpdf_transformpage.h>
#include <fpdfview.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <string>
#include <utility>

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

class ScopedBitmap final {
 public:
  explicit ScopedBitmap(FPDF_BITMAP bitmap) : bitmap_(bitmap) {}
  ScopedBitmap(const ScopedBitmap&) = delete;
  ScopedBitmap& operator=(const ScopedBitmap&) = delete;
  ~ScopedBitmap() {
    if (bitmap_ != nullptr) FPDFBitmap_Destroy(bitmap_);
  }

  FPDF_BITMAP get() const { return bitmap_; }

 private:
  FPDF_BITMAP bitmap_ = nullptr;
};

class ScopedPageObject final {
 public:
  explicit ScopedPageObject(FPDF_PAGEOBJECT object) : object_(object) {}
  ScopedPageObject(const ScopedPageObject&) = delete;
  ScopedPageObject& operator=(const ScopedPageObject&) = delete;
  ~ScopedPageObject() {
    if (object_ != nullptr) FPDFPageObj_Destroy(object_);
  }

  FPDF_PAGEOBJECT get() const { return object_; }
  FPDF_PAGEOBJECT release() { return std::exchange(object_, nullptr); }

 private:
  FPDF_PAGEOBJECT object_ = nullptr;
};

struct VectorFileWriter final {
  FPDF_FILEWRITE api{1, &writeBlock};
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

PdfiumError fail(PdfiumErrorCode code, std::string message) {
  return {code, std::move(message)};
}

bool finite(double value) {
  return std::isfinite(value);
}

bool winAnsi(char16_t character) {
  if ((character >= 0x0020 && character <= 0x007E) ||
      (character >= 0x00A0 && character <= 0x00FF)) {
    return true;
  }
  switch (character) {
    case 0x20AC: case 0x201A: case 0x0192: case 0x201E: case 0x2026:
    case 0x2020: case 0x2021: case 0x02C6: case 0x2030: case 0x0160:
    case 0x2039: case 0x0152: case 0x017D: case 0x2018: case 0x2019:
    case 0x201C: case 0x201D: case 0x2022: case 0x2013: case 0x2014:
    case 0x02DC: case 0x2122: case 0x0161: case 0x203A: case 0x0153:
    case 0x017E: case 0x0178:
      return true;
    default:
      return false;
  }
}

bool sameGeometry(const PdfiumPageMetadata& expected,
                  const PdfiumPageMetadata& actual) {
  constexpr double kTolerance = 1e-4;
  return expected.rotation == actual.rotation &&
      std::abs(expected.width - actual.width) <= kTolerance &&
      std::abs(expected.height - actual.height) <= kTolerance &&
      std::abs(expected.mediaBoxLeft - actual.mediaBoxLeft) <= kTolerance &&
      std::abs(expected.mediaBoxBottom - actual.mediaBoxBottom) <= kTolerance &&
      std::abs(expected.mediaBoxRight - actual.mediaBoxRight) <= kTolerance &&
      std::abs(expected.mediaBoxTop - actual.mediaBoxTop) <= kTolerance;
}

PdfiumError inspectPage(FPDF_DOCUMENT document,
                        std::size_t index,
                        PdfiumPageMetadata& metadata) {
  ScopedPage page(FPDF_LoadPage(document, static_cast<int>(index)));
  if (page.get() == nullptr) {
    return fail(PdfiumErrorCode::ValidationFailed,
                "PDFium could not open a signed candidate page");
  }
  const double width = FPDF_GetPageWidth(page.get());
  const double height = FPDF_GetPageHeight(page.get());
  const int rotation = FPDFPage_GetRotation(page.get());
  float left = 0.0f;
  float bottom = 0.0f;
  float right = 0.0f;
  float top = 0.0f;
  if (!finite(width) || !finite(height) || !(width > 0.0) || !(height > 0.0) ||
      rotation < 0 || rotation > 3 ||
      !FPDFPage_GetMediaBox(page.get(), &left, &bottom, &right, &top) ||
      !finite(left) || !finite(bottom) || !finite(right) || !finite(top) ||
      !(right > left) || !(top > bottom)) {
    return fail(PdfiumErrorCode::ValidationFailed,
                "PDFium candidate has invalid page geometry");
  }
  metadata.pageIndex = index;
  metadata.width = width;
  metadata.height = height;
  metadata.rotation = rotation;
  metadata.mediaBoxLeft = left;
  metadata.mediaBoxBottom = bottom;
  metadata.mediaBoxRight = right;
  metadata.mediaBoxTop = top;
  return {};
}

PdfiumError validateText(const PdfiumExportTextLine& line) {
  if (line.rightToLeft) {
    return fail(PdfiumErrorCode::UnsupportedText,
                "iOS PDF text export supports left-to-right WinAnsi text only");
  }
  if (line.text.empty() || !finite(line.left) ||
      !finite(line.baselineFromTop) || !finite(line.fontSize) ||
      !(line.fontSize > 0.0)) {
    return fail(PdfiumErrorCode::InvalidInput,
                "PDF export text line has invalid geometry");
  }
  if (std::any_of(line.text.begin(), line.text.end(), [](char16_t character) {
        return character == 0 || !winAnsi(character);
      })) {
    return fail(PdfiumErrorCode::UnsupportedText,
                "iOS PDF text export supports WinAnsi characters only");
  }
  return {};
}

PdfiumError appendInk(FPDF_DOCUMENT document,
                      FPDF_PAGE page,
                      const PdfiumPageMetadata& geometry,
                      const PdfiumInkBitmap& ink,
                      std::vector<std::unique_ptr<ScopedBitmap>>& bitmaps) {
  if (ink.width <= 0 || ink.height <= 0 || ink.width > 0x7fffffff / 4 ||
      ink.stride != ink.width * 4 ||
      ink.height > 0x7fffffff / ink.stride ||
      ink.bgra.size() !=
          static_cast<std::size_t>(ink.stride) * ink.height ||
      !finite(ink.left) || !finite(ink.top) || !finite(ink.displayWidth) ||
      !finite(ink.displayHeight) || !(ink.displayWidth > 0.0) ||
      !(ink.displayHeight > 0.0) || ink.left < 0.0 || ink.top < 0.0 ||
      ink.left + ink.displayWidth > geometry.canonicalWidth() + 1e-4 ||
      ink.top + ink.displayHeight > geometry.canonicalHeight() + 1e-4) {
    return fail(PdfiumErrorCode::InvalidInput,
                "PDF export ink bitmap has invalid dimensions or placement");
  }

  FPDF_BITMAP bitmap = FPDFBitmap_CreateEx(ink.width, ink.height,
                                            FPDFBitmap_BGRA, ink.bgra.data(),
                                            ink.stride);
  if (bitmap == nullptr) {
    return fail(PdfiumErrorCode::MutationFailed,
                "PDFium could not create the ink bitmap");
  }
  auto scopedBitmap = std::make_unique<ScopedBitmap>(bitmap);
  FPDF_PAGEOBJECT object = FPDFPageObj_NewImageObj(document);
  if (object == nullptr) {
    return fail(PdfiumErrorCode::MutationFailed,
                "PDFium could not create the ink image object");
  }

  FPDF_PAGE pages[] = {page};
  const double pdfLeft = geometry.mediaBoxLeft + ink.left;
  const double pdfBottom = geometry.mediaBoxBottom + geometry.canonicalHeight() -
      ink.top - ink.displayHeight;
  if (!FPDFImageObj_SetBitmap(pages, 1, object, bitmap) ||
      !FPDFImageObj_SetMatrix(object, ink.displayWidth, 0.0, 0.0,
                              ink.displayHeight, pdfLeft, pdfBottom)) {
    FPDFPageObj_Destroy(object);
    return fail(PdfiumErrorCode::MutationFailed,
                "PDFium could not configure the ink image object");
  }
  // FPDFPage_InsertObject takes ownership on both success and failure.
  if (!FPDFPage_InsertObject(page, object)) {
    return fail(PdfiumErrorCode::MutationFailed,
                "PDFium could not insert the ink image object");
  }
  bitmaps.push_back(std::move(scopedBitmap));
  return {};
}

PdfiumError appendText(FPDF_DOCUMENT document,
                       FPDF_PAGE page,
                       const PdfiumPageMetadata& geometry,
                       const PdfiumExportTextLine& line) {
  auto validation = validateText(line);
  if (!validation.ok()) return validation;
  FPDF_PAGEOBJECT object = FPDFPageObj_NewTextObj(
      document, "Helvetica", static_cast<float>(line.fontSize));
  if (object == nullptr) {
    return fail(PdfiumErrorCode::MutationFailed,
                "PDFium could not create a text object");
  }
  ScopedPageObject scopedObject(object);
  static_assert(sizeof(FPDF_WCHAR) == sizeof(char16_t));
  const auto* text = reinterpret_cast<const FPDF_WCHAR*>(line.text.c_str());
  const auto color = line.color;
  const FS_MATRIX matrix{
      1.0f, 0.0f, 0.0f, 1.0f,
      static_cast<float>(geometry.mediaBoxLeft + line.left),
      static_cast<float>(geometry.mediaBoxBottom + geometry.canonicalHeight() -
                         line.baselineFromTop)};
  if (!FPDFText_SetText(object, text) ||
      !FPDFTextObj_SetTextRenderMode(object, FPDF_TEXTRENDERMODE_FILL) ||
      !FPDFPageObj_SetFillColor(object,
                                (color >> 16) & 0xFF,
                                (color >> 8) & 0xFF,
                                color & 0xFF,
                                (color >> 24) & 0xFF) ||
      !FPDFPageObj_TransformF(object, &matrix)) {
    return fail(PdfiumErrorCode::MutationFailed,
                "PDFium could not set text contents or placement");
  }
  // FPDFPage_InsertObject takes ownership on both success and failure.
  if (!FPDFPage_InsertObject(page, scopedObject.release())) {
    return fail(PdfiumErrorCode::MutationFailed,
                "PDFium could not insert a text object");
  }
  return {};
}

}  // namespace

PdfiumSignedExportResult PdfiumSignedDocumentExporter::write(
    const std::vector<std::uint8_t>& sourceBytes,
    const std::vector<PdfiumSignedExportPage>& pages) {
  PdfiumSignedExportResult result;
  if (sourceBytes.empty() ||
      sourceBytes.size() > static_cast<std::size_t>((std::numeric_limits<int>::max)()) ||
      pages.empty()) {
    result.error = fail(PdfiumErrorCode::InvalidInput,
                        "PDF export source or page snapshot is empty");
    return result;
  }
  for (std::size_t index = 0; index < pages.size(); ++index) {
    const auto& page = pages[index];
    const auto& geometry = page.expectedGeometry;
    if (geometry.pageIndex != index || geometry.rotation < 0 || geometry.rotation > 3 ||
        !finite(geometry.width) || !finite(geometry.height) ||
        !(geometry.width > 0.0) || !(geometry.height > 0.0) ||
        !finite(geometry.mediaBoxLeft) || !finite(geometry.mediaBoxBottom) ||
        !finite(geometry.mediaBoxRight) || !finite(geometry.mediaBoxTop) ||
        !(geometry.mediaBoxRight > geometry.mediaBoxLeft) ||
        !(geometry.mediaBoxTop > geometry.mediaBoxBottom)) {
      result.error = fail(PdfiumErrorCode::InvalidInput,
                          "PDF export page snapshot is not ordered or has invalid geometry");
      return result;
    }
    for (const auto& line : page.textLines) {
      result.error = validateText(line);
      if (!result.error.ok()) return result;
    }
  }

  PdfiumError libraryError;
  auto library = PdfiumLibrary::acquire(libraryError);
  if (!library) {
    result.error = libraryError.ok()
        ? fail(PdfiumErrorCode::LibraryInitializationFailed,
               "Unable to initialize PDFium for export")
        : libraryError;
    return result;
  }

  PdfiumError operationError;
  {
    auto& libraryState = pdfiumLibraryState();
    std::lock_guard apiLock(libraryState.apiMutex);
    FPDF_DOCUMENT document = FPDF_LoadMemDocument(
        sourceBytes.data(), static_cast<int>(sourceBytes.size()), nullptr);
    if (document == nullptr) {
      operationError = fail(PdfiumErrorCode::DocumentOpenFailed,
                            "PDFium could not open the export source");
    }
    ScopedDocument documentScope(document);
    if (operationError.ok() &&
        (FPDF_GetSecurityHandlerRevision(document) >= 0 ||
         FPDF_GetPageCount(document) != static_cast<int>(pages.size()))) {
      operationError = fail(PdfiumErrorCode::ValidationFailed,
                            "PDF export source does not match the page snapshot");
    }

    std::vector<FPDF_PAGE> loadedPages(pages.size(), nullptr);
    std::vector<std::unique_ptr<ScopedPage>> pageScopes;
    pageScopes.reserve(pages.size());
    for (std::size_t index = 0; operationError.ok() && index < pages.size(); ++index) {
      PdfiumPageMetadata actual;
      operationError = inspectPage(document, index, actual);
      if (!operationError.ok()) break;
      if (!sameGeometry(pages[index].expectedGeometry, actual)) {
        operationError = fail(PdfiumErrorCode::ValidationFailed,
                              "PDF export source geometry changed after snapshot capture");
        break;
      }
      auto page = std::make_unique<ScopedPage>(
          FPDF_LoadPage(document, static_cast<int>(index)));
      if (page->get() == nullptr) {
        operationError = fail(PdfiumErrorCode::PageOpenFailed,
                              "PDFium could not open a source page for export");
        break;
      }
      loadedPages[index] = page->get();
      pageScopes.push_back(std::move(page));
    }

    std::vector<std::unique_ptr<ScopedBitmap>> bitmaps;
    for (std::size_t index = 0; operationError.ok() && index < pages.size(); ++index) {
      const auto& snapshot = pages[index];
      if (snapshot.ink.has_value()) {
        operationError = appendInk(document, loadedPages[index],
                                   snapshot.expectedGeometry, *snapshot.ink,
                                   bitmaps);
        if (!operationError.ok()) break;
      }
      for (const auto& line : snapshot.textLines) {
        operationError = appendText(document, loadedPages[index],
                                    snapshot.expectedGeometry, line);
        if (!operationError.ok()) break;
      }
      if (operationError.ok() &&
          !FPDFPage_GenerateContent(loadedPages[index])) {
        operationError = fail(PdfiumErrorCode::MutationFailed,
                              "PDFium could not generate signed page content");
      }
    }

    VectorFileWriter writer;
    if (operationError.ok() &&
        (!FPDF_SaveAsCopy(document, &writer.api, FPDF_NO_INCREMENTAL) ||
         writer.bytes.empty())) {
      operationError = fail(PdfiumErrorCode::SaveFailed,
                            "PDFium could not save the signed candidate");
    }
    pageScopes.clear();
    bitmaps.clear();

    if (operationError.ok()) {
      FPDF_DOCUMENT candidate = FPDF_LoadMemDocument(
          writer.bytes.data(), static_cast<int>(writer.bytes.size()), nullptr);
      if (candidate == nullptr) {
        operationError = fail(PdfiumErrorCode::ValidationFailed,
                              "PDFium could not reopen the signed candidate");
      } else {
        ScopedDocument candidateScope(candidate);
        if (FPDF_GetPageCount(candidate) != static_cast<int>(pages.size())) {
          operationError = fail(PdfiumErrorCode::ValidationFailed,
                                "Signed candidate page count changed");
        }
        for (std::size_t index = 0; operationError.ok() && index < pages.size(); ++index) {
          PdfiumPageMetadata actual;
          operationError = inspectPage(candidate, index, actual);
          if (operationError.ok() &&
              !sameGeometry(pages[index].expectedGeometry, actual)) {
            operationError = fail(PdfiumErrorCode::ValidationFailed,
                                  "Signed candidate page geometry changed");
          }
        }
      }
    }
    if (operationError.ok()) result.bytes = std::move(writer.bytes);
  }

  result.error = std::move(operationError);
  return result;
}

}  // namespace margelo::nitro::inksignpdf::pdfium
