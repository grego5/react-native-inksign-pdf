#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include "pdfium-adapter/PdfiumFontFallback.hpp"
#include "pdfium-adapter/PdfiumLibraryInternal.hpp"

#include <fpdf_edit.h>
#include <fpdf_transformpage.h>
#include <fpdfview.h>

#include <cassert>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

PdfiumLibraryState& pdfiumLibraryState() {
  static PdfiumLibraryState state;
  return state;
}

namespace {

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

class ScopedDocument final {
 public:
  explicit ScopedDocument(FPDF_DOCUMENT document) : document_(document) {}
  ScopedDocument(const ScopedDocument&) = delete;
  ScopedDocument& operator=(const ScopedDocument&) = delete;
  ~ScopedDocument() {
    if (document_ == nullptr) return;
    auto& state = pdfiumLibraryState();
    std::lock_guard apiLock(state.apiMutex);
    FPDF_CloseDocument(document_);
  }

  FPDF_DOCUMENT get() const { return document_; }
  FPDF_DOCUMENT release() {
    return std::exchange(document_, nullptr);
  }

 private:
  FPDF_DOCUMENT document_ = nullptr;
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

}  // namespace

PdfiumLibrary::PdfiumLibrary(PdfiumLibrary&& other) noexcept
    : acquired_(std::exchange(other.acquired_, false)) {}

PdfiumLibrary& PdfiumLibrary::operator=(PdfiumLibrary&& other) noexcept {
  if (this == &other) return *this;
  if (acquired_) {
    auto& state = pdfiumLibraryState();
    std::scoped_lock lock(state.lifecycleMutex, state.apiMutex);
    assert(state.activeLeases > 0);
    if (state.activeLeases > 0 && --state.activeLeases == 0) {
      FPDF_DestroyLibrary();
      uninstallSystemFontProvider();
    }
  }
  acquired_ = std::exchange(other.acquired_, false);
  return *this;
}

PdfiumLibrary::~PdfiumLibrary() {
  if (!acquired_) return;

  auto& state = pdfiumLibraryState();
  std::scoped_lock lock(state.lifecycleMutex, state.apiMutex);
  assert(state.activeLeases > 0);
  if (state.activeLeases > 0 && --state.activeLeases == 0) {
    FPDF_DestroyLibrary();
    uninstallSystemFontProvider();
  }
  acquired_ = false;
}

std::unique_ptr<PdfiumLibrary> PdfiumLibrary::acquire(PdfiumError& error) {
  auto& state = pdfiumLibraryState();
  std::scoped_lock lock(state.lifecycleMutex, state.apiMutex);
  if (state.activeLeases == 0) {
    FPDF_LIBRARY_CONFIG config{};
    config.version = 2;
    config.m_pIsolate = nullptr;
    config.m_v8EmbedderSlot = 0;
    FPDF_InitLibraryWithConfig(&config);

    if (!installSystemFontProvider()) {
      FPDF_DestroyLibrary();
      error = {PdfiumErrorCode::LibraryInitializationFailed,
               "Unable to install the PDFium system font provider"};
      return nullptr;
    }
  }
  ++state.activeLeases;
  error = {};
  return std::unique_ptr<PdfiumLibrary>(new PdfiumLibrary(true));
}

struct PdfiumDocumentSession::Impl final {
  Impl(std::unique_ptr<PdfiumLibrary> library,
       std::vector<std::uint8_t> documentBytes,
       FPDF_DOCUMENT document,
       std::size_t pageCount)
      : library(std::move(library)),
        documentBytes(std::move(documentBytes)),
        document(document),
        pageCount(pageCount) {}

  std::unique_ptr<PdfiumLibrary> library;
  std::vector<std::uint8_t> documentBytes;
  FPDF_DOCUMENT document = nullptr;
  std::size_t pageCount = 0;
  std::unique_ptr<FontSubstitutionRegistry> fontRegistry =
      std::make_unique<FontSubstitutionRegistry>();
};

PdfiumDocumentSession::PdfiumDocumentSession(
    std::unique_ptr<PdfiumLibrary> library,
    std::vector<std::uint8_t> documentBytes,
    void* document,
    std::size_t pageCount)
    : impl_(std::make_unique<Impl>(std::move(library),
                                   std::move(documentBytes),
                                   static_cast<FPDF_DOCUMENT>(document),
                                   pageCount)) {}

PdfiumDocumentSession::PdfiumDocumentSession(
    PdfiumDocumentSession&& other) noexcept
    : impl_(std::move(other.impl_)) {}

PdfiumDocumentSession& PdfiumDocumentSession::operator=(
    PdfiumDocumentSession&& other) noexcept {
  if (this == &other) return *this;
  closeUnchecked();
  impl_ = std::move(other.impl_);
  return *this;
}

PdfiumDocumentSession::~PdfiumDocumentSession() {
  closeUnchecked();
}

PdfiumOpenResult PdfiumDocumentSession::open(
    std::vector<std::uint8_t> documentBytes,
    std::string password,
    std::optional<PdfiumFallbackFont> fallbackFont) {
  PdfiumOpenResult result;
  if (documentBytes.empty()) {
    result.error = {PdfiumErrorCode::InvalidInput,
                    "PDFium document bytes must not be empty"};
    return result;
  }
  if (documentBytes.size() >
      static_cast<std::size_t>((std::numeric_limits<int>::max)())) {
    result.error = {PdfiumErrorCode::InvalidInput,
                    "PDFium document exceeds the supported byte size"};
    return result;
  }

  auto fontRegistry = std::make_unique<FontSubstitutionRegistry>();
  if (fallbackFont.has_value()) {
    std::string fontError;
    if (!fontRegistry->setSuppliedFont(
            fallbackFont->path, fallbackFont->collectionIndex, &fontError)) {
      result.error = {
          PdfiumErrorCode::InvalidFallbackFont,
          "Invalid fallback font: " + fontError};
      return result;
    }
  }

  PdfiumError libraryError;
  auto library = PdfiumLibrary::acquire(libraryError);
  if (!library) {
    result.error = libraryError.ok()
        ? PdfiumError{PdfiumErrorCode::LibraryInitializationFailed,
                      "Unable to initialize PDFium"}
        : libraryError;
    return result;
  }

  FPDF_DOCUMENT renderingRaw = nullptr;
  unsigned long loadError = 0;
  {
    auto& state = pdfiumLibraryState();
    std::lock_guard apiLock(state.apiMutex);
    ScopedFontRegistry activeRegistry(fontRegistry.get());
    renderingRaw = FPDF_LoadMemDocument(
        documentBytes.data(),
        static_cast<int>(documentBytes.size()),
        password.empty() ? nullptr : password.c_str());
    if (renderingRaw == nullptr) loadError = FPDF_GetLastError();
  }
  if (renderingRaw == nullptr) {
    result.error = {PdfiumErrorCode::DocumentOpenFailed,
                    "PDFium rendering document open failed (PDFium error " +
                        std::to_string(loadError) + ")"};
    return result;
  }

  ScopedDocument renderingDocument(renderingRaw);
  std::size_t pageCount = 0;
  {
    auto& state = pdfiumLibraryState();
    std::lock_guard apiLock(state.apiMutex);
    ScopedFontRegistry activeRegistry(fontRegistry.get());
    const int count = FPDF_GetPageCount(renderingDocument.get());
    if (count > 0) pageCount = static_cast<std::size_t>(count);
  }
  if (pageCount == 0) {
    result.error = {PdfiumErrorCode::DocumentOpenFailed,
                    "PDFium rendering document contains no pages"};
    return result;
  }

  try {
    result.session = std::unique_ptr<PdfiumDocumentSession>(
        new PdfiumDocumentSession(std::move(library),
                                  std::move(documentBytes),
                                  renderingDocument.get(),
                                  pageCount));
    renderingDocument.release();
    result.session->impl_->fontRegistry = std::move(fontRegistry);
    result.error = {};
  } catch (...) {
    result.error = {PdfiumErrorCode::DocumentOpenFailed,
                    "Unable to allocate the PDFium document session"};
  }
  return result;
}

std::size_t PdfiumDocumentSession::pageCount() const {
  return impl_ ? impl_->pageCount : 0;
}

PdfiumError PdfiumDocumentSession::inspectPage(
    std::size_t pageIndex,
    PdfiumPageMetadata& metadata) const {
  if (!impl_) {
    return {PdfiumErrorCode::Closed, "PDFium document session is closed"};
  }
  if (pageIndex >= impl_->pageCount) {
    return {PdfiumErrorCode::InvalidPageIndex,
            "PDFium page index is outside the document"};
  }

  auto& state = pdfiumLibraryState();
  std::lock_guard apiLock(state.apiMutex);
  ScopedFontRegistry activeRegistry(impl_->fontRegistry.get());
  ScopedPage page(FPDF_LoadPage(impl_->document, static_cast<int>(pageIndex)));
  if (page.get() == nullptr) {
    const auto error = FPDF_GetLastError();
    return {PdfiumErrorCode::PageOpenFailed,
            "FPDF_LoadPage failed (PDFium error " + std::to_string(error) +
                ")"};
  }
  const double width = FPDF_GetPageWidth(page.get());
  const double height = FPDF_GetPageHeight(page.get());
  float mediaBoxLeft = 0.0f;
  float mediaBoxBottom = 0.0f;
  float mediaBoxRight = 0.0f;
  float mediaBoxTop = 0.0f;
  if (!FPDFPage_GetMediaBox(page.get(), &mediaBoxLeft, &mediaBoxBottom,
                            &mediaBoxRight, &mediaBoxTop)) {
    return {PdfiumErrorCode::PageOpenFailed,
            "PDFium page has no readable MediaBox"};
  }
  if (!(width > 0.0) || !(height > 0.0) ||
      !std::isfinite(width) || !std::isfinite(height) ||
      !std::isfinite(mediaBoxLeft) || !std::isfinite(mediaBoxBottom) ||
      !std::isfinite(mediaBoxRight) || !std::isfinite(mediaBoxTop) ||
      !(mediaBoxRight > mediaBoxLeft) || !(mediaBoxTop > mediaBoxBottom)) {
    return {PdfiumErrorCode::PageOpenFailed,
            "PDFium page has invalid dimensions"};
  }
  const int rotation = FPDFPage_GetRotation(page.get());
  if (rotation < 0 || rotation > 3) {
    return {PdfiumErrorCode::PageOpenFailed,
            "PDFium page has invalid rotation"};
  }
  metadata.pageIndex = pageIndex;
  metadata.width = width;
  metadata.height = height;
  metadata.rotation = rotation;
  metadata.mediaBoxLeft = mediaBoxLeft;
  metadata.mediaBoxBottom = mediaBoxBottom;
  metadata.mediaBoxRight = mediaBoxRight;
  metadata.mediaBoxTop = mediaBoxTop;
  return {};
}

PdfiumError PdfiumDocumentSession::inspectHorizontalSnapCandidates(
    std::size_t pageIndex,
    std::vector<PdfiumHorizontalSnapCandidate>& candidates) const {
  candidates.clear();
  if (!impl_) {
    return {PdfiumErrorCode::Closed, "PDFium document session is closed"};
  }
  if (pageIndex >= impl_->pageCount) {
    return {PdfiumErrorCode::InvalidPageIndex,
            "PDFium page index is outside the document"};
  }

  struct Point final { double x; double y; };
  struct Shape final {
    double left;
    double right;
    double centerY;
  };

  auto& state = pdfiumLibraryState();
  std::lock_guard apiLock(state.apiMutex);
  ScopedFontRegistry activeRegistry(impl_->fontRegistry.get());
  ScopedPage page(FPDF_LoadPage(impl_->document, static_cast<int>(pageIndex)));
  if (page.get() == nullptr) {
    const auto error = FPDF_GetLastError();
    return {PdfiumErrorCode::PageOpenFailed,
            "FPDF_LoadPage failed (PDFium error " + std::to_string(error) +
                ")"};
  }

  const double pageWidth = FPDF_GetPageWidth(page.get());
  const double pageHeight = FPDF_GetPageHeight(page.get());
  if (!std::isfinite(pageWidth) || !std::isfinite(pageHeight) ||
      pageWidth <= 0.0 || pageHeight <= 0.0 ||
      pageWidth > static_cast<double>((std::numeric_limits<int>::max)()) ||
      pageHeight > static_cast<double>((std::numeric_limits<int>::max)())) {
    return {PdfiumErrorCode::PageOpenFailed,
            "PDFium page geometry is invalid"};
  }
  const auto deviceWidth = static_cast<int>(std::ceil(pageWidth));
  const auto deviceHeight = static_cast<int>(std::ceil(pageHeight));
  const auto toDisplayPoint = [&](double x, double y) -> std::optional<Point> {
    if (!std::isfinite(x) || !std::isfinite(y)) return std::nullopt;
    int deviceX = 0;
    int deviceY = 0;
    // The loaded page matrix already applies its intrinsic /Rotate value.
    // Zero here asks PDFium only for the top-left, upright page coordinates.
    if (!FPDF_PageToDevice(page.get(), 0, 0, deviceWidth, deviceHeight,
                           0, x, y, &deviceX, &deviceY)) {
      return std::nullopt;
    }
    return Point{static_cast<double>(deviceX) * pageWidth /
                     static_cast<double>(deviceWidth),
                 static_cast<double>(deviceY) * pageHeight /
                     static_cast<double>(deviceHeight)};
  };
  const auto appendLine = [&](Point first, Point last) {
    if (std::abs(first.y - last.y) > 2.0 ||
        std::abs(first.x - last.x) < 50.0) {
      return;
    }
    const double left = std::max(0.0, std::min(first.x, last.x));
    const double right = std::min(pageWidth, std::max(first.x, last.x));
    const double centerY = (first.y + last.y) / 2.0;
    if (right > left && centerY >= 0.0 && centerY <= pageHeight) {
      candidates.push_back({left, right, centerY});
    }
  };

  std::vector<Shape> filledShapes;
  const int objectCount = FPDFPage_CountObjects(page.get());
  for (int objectIndex = 0; objectIndex < objectCount; ++objectIndex) {
    FPDF_PAGEOBJECT object = FPDFPage_GetObject(page.get(), objectIndex);
    if (object == nullptr || FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_PATH) {
      continue;
    }
    int fillMode = FPDF_FILLMODE_NONE;
    FPDF_BOOL stroke = false;
    if (!FPDFPath_GetDrawMode(object, &fillMode, &stroke)) continue;
    if (stroke) {
      FS_MATRIX matrix{};
      if (FPDFPageObj_GetMatrix(object, &matrix)) {
        const int segmentCount = FPDFPath_CountSegments(object);
        std::optional<Point> current;
        for (int segmentIndex = 0; segmentIndex < segmentCount; ++segmentIndex) {
          FPDF_PATHSEGMENT segment = FPDFPath_GetPathSegment(object, segmentIndex);
          if (segment == nullptr) continue;
          const int type = FPDFPathSegment_GetType(segment);
          FPDF_PATHSEGMENT pointSegment = segment;
          if (type == FPDF_SEGMENT_BEZIERTO) {
            pointSegment = FPDFPath_GetPathSegment(object, segmentIndex + 2);
            if (pointSegment == nullptr ||
                FPDFPathSegment_GetType(pointSegment) != FPDF_SEGMENT_BEZIERTO) {
              current.reset();
              continue;
            }
            segmentIndex += 2;
          }
          float x = 0.0f;
          float y = 0.0f;
          if (!FPDFPathSegment_GetPoint(pointSegment, &x, &y)) {
            current.reset();
            continue;
          }
          // Segment points are path-local; apply the page-object matrix once.
          const Point point{
              matrix.a * x + matrix.c * y + matrix.e,
              matrix.b * x + matrix.d * y + matrix.f};
          if (type == FPDF_SEGMENT_MOVETO) {
            current = point;
          } else if (type == FPDF_SEGMENT_LINETO && current) {
            const auto first = toDisplayPoint(current->x, current->y);
            const auto last = toDisplayPoint(point.x, point.y);
            if (first && last) appendLine(*first, *last);
            current = point;
          } else {
            current = point;
          }
        }
      }
    }
    float left = 0.0f;
    float bottom = 0.0f;
    float right = 0.0f;
    float top = 0.0f;
    if (!FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top)) continue;
    const std::array<Point, 4> bounds = {
        Point{left, bottom}, Point{left, top},
        Point{right, bottom}, Point{right, top}};
    double minX = (std::numeric_limits<double>::infinity)();
    double minY = (std::numeric_limits<double>::infinity)();
    double maxX = -(std::numeric_limits<double>::infinity)();
    double maxY = -(std::numeric_limits<double>::infinity)();
    bool validBounds = true;
    for (const auto& corner : bounds) {
      const auto display = toDisplayPoint(corner.x, corner.y);
      if (!display) {
        validBounds = false;
        break;
      }
      minX = std::min(minX, display->x);
      minY = std::min(minY, display->y);
      maxX = std::max(maxX, display->x);
      maxY = std::max(maxY, display->y);
    }
    if (!validBounds) continue;
    const double width = maxX - minX;
    const double height = maxY - minY;
    const double clippedLeft = std::max(0.0, minX);
    const double clippedRight = std::min(pageWidth, maxX);
    const double centerY = (minY + maxY) / 2.0;
    if (fillMode != FPDF_FILLMODE_NONE && width > 0.1 && height > 0.1 &&
        width <= 8.0 && height <= 8.0 && clippedRight > clippedLeft &&
        centerY >= 0.0 && centerY <= pageHeight) {
      filledShapes.push_back({clippedLeft, clippedRight, centerY});
    }
  }

  std::sort(filledShapes.begin(), filledShapes.end(),
            [](const Shape& left, const Shape& right) {
              return left.centerY < right.centerY;
            });
  for (std::size_t rowBegin = 0; rowBegin < filledShapes.size();) {
    const double rowY = filledShapes[rowBegin].centerY;
    std::size_t rowEnd = rowBegin + 1;
    while (rowEnd < filledShapes.size() &&
           std::abs(filledShapes[rowEnd].centerY - rowY) <= 2.5) {
      ++rowEnd;
    }
    std::sort(filledShapes.begin() + static_cast<std::ptrdiff_t>(rowBegin),
              filledShapes.begin() + static_cast<std::ptrdiff_t>(rowEnd),
              [](const Shape& left, const Shape& right) {
                return left.left < right.left;
              });
    std::size_t runBegin = rowBegin;
    while (runBegin < rowEnd) {
      std::size_t runEnd = runBegin + 1;
      std::vector<double> gaps;
      while (runEnd < rowEnd) {
        const double gap =
            (filledShapes[runEnd].left + filledShapes[runEnd].right) / 2.0 -
            (filledShapes[runEnd - 1].left + filledShapes[runEnd - 1].right) / 2.0;
        if (gap < 1.0 || gap > 20.0) break;
        gaps.push_back(gap);
        if (gaps.size() >= 2) {
          const double mean = (gaps.front() + gaps.back()) / 2.0;
          if (std::abs(gap - mean) > std::max(1.5, mean * 0.4)) break;
        }
        ++runEnd;
      }
      if (runEnd - runBegin >= 4) {
        candidates.push_back({filledShapes[runBegin].left,
                              filledShapes[runEnd - 1].right, rowY});
      }
      runBegin = runEnd;
    }
    rowBegin = rowEnd;
  }
  return {};
}

PdfiumError PdfiumDocumentSession::renderPage(
    const PdfiumPageRenderRequest& request) const {
  if (!impl_) {
    return {PdfiumErrorCode::Closed, "PDFium document session is closed"};
  }
  if (request.pageIndex >= impl_->pageCount) {
    return {PdfiumErrorCode::InvalidPageIndex,
            "PDFium page index is outside the document"};
  }
  if (request.width <= 0 || request.height <= 0 || request.stride <= 0 ||
      request.width > (std::numeric_limits<std::int32_t>::max)() / 4 ||
      request.stride < request.width * 4) {
    return {PdfiumErrorCode::InvalidInput,
            "PDFium render dimensions or stride are invalid"};
  }

  const auto requiredBytes = static_cast<std::size_t>(request.stride) *
      static_cast<std::size_t>(request.height);
  if (static_cast<std::size_t>(request.height) != 0 &&
      requiredBytes / static_cast<std::size_t>(request.height) !=
          static_cast<std::size_t>(request.stride)) {
    return {PdfiumErrorCode::InvalidInput,
            "PDFium render buffer size overflows"};
  }
  if (request.bgra.size() < requiredBytes) {
    return {PdfiumErrorCode::InvalidInput,
            "PDFium render buffer is smaller than the requested bitmap"};
  }

  const auto& matrix = request.pageToDevice;
  const auto determinant = matrix.a * matrix.d - matrix.b * matrix.c;
  if (!std::isfinite(matrix.a) || !std::isfinite(matrix.b) ||
      !std::isfinite(matrix.c) || !std::isfinite(matrix.d) ||
      !std::isfinite(matrix.e) || !std::isfinite(matrix.f) ||
      !std::isfinite(determinant) || std::abs(determinant) <= 1e-12) {
    return {PdfiumErrorCode::InvalidInput,
            "PDFium render transform must be finite and invertible"};
  }

  const auto& clip = request.clip;
  if (!std::isfinite(clip.left) || !std::isfinite(clip.top) ||
      !std::isfinite(clip.right) || !std::isfinite(clip.bottom) ||
      clip.left < 0.0 || clip.top < 0.0 || clip.right > request.width ||
      clip.bottom > request.height || clip.right <= clip.left ||
      clip.bottom <= clip.top) {
    return {PdfiumErrorCode::InvalidInput,
            "PDFium render clip is outside the destination bitmap"};
  }

  constexpr std::uint32_t kAllowedFlags = FPDF_ANNOT | FPDF_LCD_TEXT |
      FPDF_NO_NATIVETEXT | FPDF_GRAYSCALE | FPDF_DEBUG_INFO | FPDF_NO_CATCH |
      FPDF_RENDER_LIMITEDIMAGECACHE | FPDF_RENDER_FORCEHALFTONE |
      FPDF_PRINTING | FPDF_RENDER_NO_SMOOTHTEXT |
      FPDF_RENDER_NO_SMOOTHIMAGE | FPDF_RENDER_NO_SMOOTHPATH |
      FPDF_REVERSE_BYTE_ORDER | FPDF_CONVERT_FILL_TO_STROKE;
  if ((request.flags & ~kAllowedFlags) != 0) {
    return {PdfiumErrorCode::InvalidInput,
            "PDFium render flags contain unsupported bits"};
  }

  auto& state = pdfiumLibraryState();
  std::lock_guard apiLock(state.apiMutex);
  ScopedFontRegistry activeRegistry(impl_->fontRegistry.get());
  ScopedPage page(FPDF_LoadPage(impl_->document,
                                static_cast<int>(request.pageIndex)));
  if (page.get() == nullptr) {
    const auto error = FPDF_GetLastError();
    return {PdfiumErrorCode::PageOpenFailed,
            "FPDF_LoadPage failed (PDFium error " +
                std::to_string(error) + ")"};
  }

  ScopedBitmap bitmap(FPDFBitmap_CreateEx(
      request.width, request.height, FPDFBitmap_BGRA, request.bgra.data(),
      request.stride));
  if (bitmap.get() == nullptr) {
    return {PdfiumErrorCode::InvalidInput,
            "FPDFBitmap_CreateEx failed"};
  }

  FPDFBitmap_FillRect(bitmap.get(), 0, 0, request.width, request.height,
                      request.background);
  const FS_MATRIX pdfiumMatrix{
      static_cast<float>(matrix.a), static_cast<float>(matrix.b),
      static_cast<float>(matrix.c), static_cast<float>(matrix.d),
      static_cast<float>(matrix.e), static_cast<float>(matrix.f)};
  const FS_RECTF pdfiumClip{
      static_cast<float>(clip.left), static_cast<float>(clip.top),
      static_cast<float>(clip.right), static_cast<float>(clip.bottom)};
  FPDF_RenderPageBitmapWithMatrix(bitmap.get(), page.get(), &pdfiumMatrix,
                                  &pdfiumClip,
                                  static_cast<int>(request.flags));
  return {};
}

PdfiumError PdfiumDocumentSession::close() noexcept {
  if (!impl_) return {};
  closeUnchecked();
  return {};
}

void PdfiumDocumentSession::closeUnchecked() noexcept {
  if (!impl_) return;

  if (impl_->document != nullptr) {
    auto& state = pdfiumLibraryState();
    {
      std::lock_guard apiLock(state.apiMutex);
      FPDF_CloseDocument(impl_->document);
    }
    impl_->document = nullptr;
  }
  impl_.reset();
}

}  // namespace margelo::nitro::inksignpdf::pdfium
