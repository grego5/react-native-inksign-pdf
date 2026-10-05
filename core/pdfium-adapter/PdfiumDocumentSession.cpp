#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include "pdfium-adapter/PdfiumFontFallback.hpp"
#include "pdfium-adapter/PdfiumLibraryInternal.hpp"

#include <fpdf_edit.h>
#include <fpdf_text.h>
#include <fpdf_transformpage.h>
#include <fpdfview.h>

#include <cassert>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iterator>
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

bool isTextWhitespace(unsigned long value) {
  return value == 0x09UL || value == 0x0AUL || value == 0x0BUL ||
      value == 0x0CUL || value == 0x0DUL || value == 0x20UL ||
      value == 0x85UL || value == 0xA0UL || value == 0x1680UL ||
      (value >= 0x2000UL && value <= 0x200AUL) ||
      value == 0x2028UL || value == 0x2029UL || value == 0x202FUL ||
      value == 0x205FUL || value == 0x3000UL;
}

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
  struct PageAnalysis final {
    std::size_t pageIndex = 0;
    double pageWidth = 0.0;
    double pageHeight = 0.0;
    bool hasText = false;
    bool hasRules = false;
    std::vector<unsigned long> text;
    std::vector<std::optional<PdfiumTextKeyMatch>> characterBounds;
    std::vector<int> visualRows;
    std::vector<double> visualRowTops;
    std::vector<double> visualRowBottoms;
    std::vector<PdfiumHorizontalSnapCandidate> rules;

    std::size_t estimatedBytes() const {
      return sizeof(PageAnalysis) + text.capacity() * sizeof(unsigned long) +
          characterBounds.capacity() * sizeof(std::optional<PdfiumTextKeyMatch>) +
          visualRows.capacity() * sizeof(int) +
          visualRowTops.capacity() * sizeof(double) +
          visualRowBottoms.capacity() * sizeof(double) +
          rules.capacity() * sizeof(PdfiumHorizontalSnapCandidate);
    }
  };

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
  // A PdfiumDocumentSession is tied to one immutable source generation. Page
  // indices are therefore stable for the lifetime of these entries.
  mutable std::vector<PageAnalysis> pageAnalyses;
  mutable std::uint64_t textExtractionCount = 0;
  mutable std::uint64_t ruleInspectionCount = 0;
  mutable std::uint64_t pageAnalysisLoadCount = 0;
  mutable std::uint64_t textCharacterCount = 0;
  mutable std::uint64_t characterGeometryCount = 0;

  PageAnalysis& analysisFor(std::size_t pageIndex) const {
    const auto found = std::find_if(pageAnalyses.begin(), pageAnalyses.end(),
        [pageIndex](const PageAnalysis& analysis) {
          return analysis.pageIndex == pageIndex;
        });
    if (found != pageAnalyses.end()) {
      if (std::next(found) != pageAnalyses.end()) {
        auto recentlyUsed = std::move(*found);
        pageAnalyses.erase(found);
        pageAnalyses.push_back(std::move(recentlyUsed));
      }
      return pageAnalyses.back();
    }
    constexpr std::size_t kMaxCachedPages = 8;
    if (pageAnalyses.size() == kMaxCachedPages) pageAnalyses.erase(pageAnalyses.begin());
    pageAnalyses.push_back(PageAnalysis{});
    pageAnalyses.back().pageIndex = pageIndex;
    return pageAnalyses.back();
  }

  void trimPageAnalyses() const {
    constexpr std::size_t kMaxCachedPages = 8;
    constexpr std::size_t kMaxEstimatedBytes = 8 * 1024 * 1024;
    const auto cachedBytes = [this] {
      std::size_t total = 0;
      for (const auto& analysis : pageAnalyses) total += analysis.estimatedBytes();
      return total;
    };
    while (!pageAnalyses.empty() &&
           (pageAnalyses.size() > kMaxCachedPages ||
            cachedBytes() > kMaxEstimatedBytes)) {
      pageAnalyses.erase(pageAnalyses.begin());
    }
  }
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
    std::vector<PdfiumHorizontalSnapCandidate>& candidates,
    bool copyCandidates) const {
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
  auto& analysis = impl_->analysisFor(pageIndex);
  if (analysis.hasRules && analysis.hasText) {
    if (copyCandidates) candidates = analysis.rules;
    return {};
  }
  const bool inspectRules = !analysis.hasRules;
  const bool extractText = !analysis.hasText;
  if (inspectRules) ++impl_->ruleInspectionCount;
  if (extractText) ++impl_->textExtractionCount;
  ScopedFontRegistry activeRegistry(impl_->fontRegistry.get());
  ScopedPage page(FPDF_LoadPage(impl_->document, static_cast<int>(pageIndex)));
  if (page.get() == nullptr) {
    const auto error = FPDF_GetLastError();
    return {PdfiumErrorCode::PageOpenFailed,
            "FPDF_LoadPage failed (PDFium error " + std::to_string(error) +
                ")"};
  }
  ++impl_->pageAnalysisLoadCount;

  const double pageWidth = FPDF_GetPageWidth(page.get());
  const double pageHeight = FPDF_GetPageHeight(page.get());
  if (!std::isfinite(pageWidth) || !std::isfinite(pageHeight) ||
      pageWidth <= 0.0 || pageHeight <= 0.0 ||
      pageWidth > static_cast<double>((std::numeric_limits<int>::max)()) ||
      pageHeight > static_cast<double>((std::numeric_limits<int>::max)())) {
    return {PdfiumErrorCode::PageOpenFailed,
            "PDFium page geometry is invalid"};
  }
  analysis.pageWidth = pageWidth;
  analysis.pageHeight = pageHeight;
  // FPDF_PageToDevice takes integer pixel coordinates. Use a higher virtual
  // resolution than one pixel per point so small vector shapes keep their
  // sub-point geometry when mapped back into page coordinates.
  constexpr double kDevicePixelsPerPoint = 64.0;
  const double coordinateScale = std::min(
      kDevicePixelsPerPoint,
      static_cast<double>((std::numeric_limits<int>::max)()) /
          std::max(pageWidth, pageHeight));
  const int deviceWidth = static_cast<int>(std::ceil(pageWidth * coordinateScale));
  const int deviceHeight = static_cast<int>(std::ceil(pageHeight * coordinateScale));
  const double sx = pageWidth / static_cast<double>(deviceWidth);
  const double sy = pageHeight / static_cast<double>(deviceHeight);

  // Both consumers share one loaded page. Keep the extracted text and drawing
  // object rules as plain cached data after this page handle is released.
  if (extractText) {
    FPDF_TEXTPAGE textPage = FPDFText_LoadPage(page.get());
    if (textPage != nullptr) {
      const int count = FPDFText_CountChars(textPage);
      impl_->textCharacterCount += static_cast<std::uint64_t>(std::max(count, 0));
      if (count > 0) {
        analysis.text.resize(static_cast<std::size_t>(count));
        analysis.characterBounds.resize(static_cast<std::size_t>(count));
      }
      const auto mapCharacterBox = [&](double left, double right, double bottom,
                                       double top, int index)
          -> std::optional<PdfiumTextKeyMatch> {
        int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
        if (!FPDF_PageToDevice(page.get(), 0, 0, deviceWidth, deviceHeight, 0,
                               left, bottom, &x0, &y0) ||
            !FPDF_PageToDevice(page.get(), 0, 0, deviceWidth, deviceHeight, 0,
                               right, top, &x1, &y1)) return std::nullopt;
        const double xMin = std::min(x0, x1) * sx;
        const double xMax = std::max(x0, x1) * sx;
        const double yMin = std::min(y0, y1) * sy;
        const double yMax = std::max(y0, y1) * sy;
        if (!std::isfinite(xMin) || !std::isfinite(xMax) || !std::isfinite(yMin) ||
            !std::isfinite(yMax) || xMax <= xMin || yMax <= yMin) return std::nullopt;
        return PdfiumTextKeyMatch{xMin, yMin, xMax, yMax, static_cast<double>(index),
                                  (yMin + yMax) / 2.0, yMax - yMin};
      };
      for (int index = 0; index < count; ++index) {
        analysis.text[static_cast<std::size_t>(index)] =
            FPDFText_GetUnicode(textPage, index);
        double left = 0.0;
        double right = 0.0;
        double bottom = 0.0;
        double top = 0.0;
        std::optional<PdfiumTextKeyMatch> characterBounds;
        if (FPDFText_GetCharBox(textPage, index, &left, &right, &bottom, &top)) {
          characterBounds = mapCharacterBox(left, right, bottom, top, index);
        }
        const bool hasSuspiciousGlyphBounds = characterBounds &&
            !isTextWhitespace(analysis.text[static_cast<std::size_t>(index)]) &&
            characterBounds->lineHeight < 0.5;
        if (!characterBounds || hasSuspiciousGlyphBounds) {
          FS_RECTF looseBounds{};
          if (FPDFText_GetLooseCharBox(textPage, index, &looseBounds)) {
            const auto mappedLooseBounds = mapCharacterBox(
                looseBounds.left, looseBounds.right, looseBounds.bottom,
                looseBounds.top, index);
            if (mappedLooseBounds && (!characterBounds ||
                mappedLooseBounds->lineHeight > characterBounds->lineHeight)) {
              characterBounds = mappedLooseBounds;
            }
          }
        }
        if (!characterBounds) continue;
        analysis.characterBounds[static_cast<std::size_t>(index)] = *characterBounds;
        ++impl_->characterGeometryCount;
      }
      analysis.visualRows.assign(static_cast<std::size_t>(count), -1);
      std::vector<std::pair<double, std::size_t>> orderedCenters;
      orderedCenters.reserve(analysis.characterBounds.size());
      for (std::size_t index = 0; index < analysis.characterBounds.size(); ++index) {
        if (isTextWhitespace(analysis.text[index])) continue;
        if (const auto& bounds = analysis.characterBounds[index]) {
          orderedCenters.emplace_back((bounds->top + bounds->bottom) / 2.0, index);
        }
      }
      std::sort(orderedCenters.begin(), orderedCenters.end());
      struct VisualRow final {
        double center;
        double height;
        std::size_t count;
        double top;
        double bottom;
      };
      std::vector<VisualRow> rows;
      for (const auto& [center, index] : orderedCenters) {
        const auto& bounds = *analysis.characterBounds[index];
        const double height = bounds.lineHeight;
        if (rows.empty() || std::abs(center - rows.back().center) >
            std::max(1.5, std::min(height, rows.back().height) * 0.35)) {
          rows.push_back({center, height, 1, bounds.top, bounds.bottom});
        } else {
          auto& row = rows.back();
          row.center = (row.center * static_cast<double>(row.count) + center) /
              static_cast<double>(row.count + 1);
          row.height = (row.height * static_cast<double>(row.count) + height) /
              static_cast<double>(row.count + 1);
          row.top = std::min(row.top, bounds.top);
          row.bottom = std::max(row.bottom, bounds.bottom);
          ++row.count;
        }
        analysis.visualRows[index] = static_cast<int>(rows.size() - 1);
      }
      analysis.visualRowTops.reserve(rows.size());
      analysis.visualRowBottoms.reserve(rows.size());
      for (const auto& row : rows) {
        analysis.visualRowTops.push_back(row.top);
        analysis.visualRowBottoms.push_back(row.bottom);
      }
      FPDFText_ClosePage(textPage);
    }
    analysis.hasText = true;
  }

  if (!inspectRules) {
    if (copyCandidates) candidates = analysis.rules;
    if (copyCandidates) impl_->trimPageAnalyses();
    return {};
  }
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
        // Compare square centers in page units. Small scaled checkbox dots may
        // be less than one point apart, but they still form a row when their
        // spacing is positive and consistent.
        if (gap <= 0.0 || gap > 20.0) break;
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
  analysis.rules = candidates;
  analysis.hasRules = true;
  if (copyCandidates) impl_->trimPageAnalyses();
  return {};
}

PdfiumError PdfiumDocumentSession::preparePageAnalysis(
    std::size_t pageIndex,
    PdfiumPageAnalysisSnapshot& snapshot) const {
  snapshot = {};
  if (!impl_) return {PdfiumErrorCode::Closed, "PDFium document session is closed"};
  if (pageIndex >= impl_->pageCount) {
    return {PdfiumErrorCode::InvalidPageIndex,
            "PDFium page index is outside the document"};
  }
  std::vector<PdfiumHorizontalSnapCandidate> unusedCandidates;
  if (const auto error = inspectHorizontalSnapCandidates(pageIndex, unusedCandidates, true);
      !error) {
    return error;
  }
  auto& state = pdfiumLibraryState();
  std::lock_guard apiLock(state.apiMutex);
  const auto found = std::find_if(impl_->pageAnalyses.begin(), impl_->pageAnalyses.end(),
      [pageIndex](const Impl::PageAnalysis& analysis) {
        return analysis.pageIndex == pageIndex && analysis.hasText && analysis.hasRules;
      });
  if (found == impl_->pageAnalyses.end()) {
    return {PdfiumErrorCode::PageOpenFailed,
            "PDFium page analysis was evicted before it could be retained"};
  }
  snapshot.pageWidth = found->pageWidth;
  snapshot.pageHeight = found->pageHeight;
  snapshot.text = found->text;
  snapshot.characterBounds = found->characterBounds;
  snapshot.visualRows = found->visualRows;
  snapshot.visualRowTops = found->visualRowTops;
  snapshot.visualRowBottoms = found->visualRowBottoms;
  snapshot.rules = found->rules;
  return {};
}

PdfiumPageAnalysisScanCounts
PdfiumDocumentSession::pageAnalysisScanCountsForTesting() const {
  if (!impl_) return {};
  auto& state = pdfiumLibraryState();
  std::lock_guard apiLock(state.apiMutex);
  return {
      impl_->textExtractionCount,
      impl_->ruleInspectionCount,
      impl_->pageAnalysisLoadCount,
      impl_->textCharacterCount,
      impl_->characterGeometryCount,
  };
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
