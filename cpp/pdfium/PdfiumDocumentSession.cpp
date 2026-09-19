#include "pdfium/PdfiumDocumentSession.hpp"

#include <fpdf_text.h>
#include <fpdfview.h>

#include <cassert>
#include <limits>
#include <mutex>
#include <thread>
#include <utility>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

struct LibraryState final {
  std::mutex lifecycleMutex;
  std::mutex apiMutex;
  std::size_t activeLeases = 0;
};

LibraryState& libraryState() {
  static LibraryState state;
  return state;
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

class ScopedTextPage final {
 public:
  explicit ScopedTextPage(FPDF_TEXTPAGE page) : page_(page) {}
  ScopedTextPage(const ScopedTextPage&) = delete;
  ScopedTextPage& operator=(const ScopedTextPage&) = delete;
  ~ScopedTextPage() {
    if (page_ != nullptr) FPDFText_ClosePage(page_);
  }

  FPDF_TEXTPAGE get() const { return page_; }

 private:
  FPDF_TEXTPAGE page_ = nullptr;
};

}  // namespace

PdfiumLibrary::PdfiumLibrary(PdfiumLibrary&& other) noexcept
    : acquired_(std::exchange(other.acquired_, false)) {}

PdfiumLibrary& PdfiumLibrary::operator=(PdfiumLibrary&& other) noexcept {
  if (this == &other) return *this;
  if (acquired_) {
    auto& state = libraryState();
    std::scoped_lock lock(state.lifecycleMutex, state.apiMutex);
    assert(state.activeLeases > 0);
    if (state.activeLeases > 0 && --state.activeLeases == 0) {
      FPDF_DestroyLibrary();
    }
  }
  acquired_ = std::exchange(other.acquired_, false);
  return *this;
}

PdfiumLibrary::~PdfiumLibrary() {
  if (!acquired_) return;

  auto& state = libraryState();
  std::scoped_lock lock(state.lifecycleMutex, state.apiMutex);
  assert(state.activeLeases > 0);
  if (state.activeLeases > 0 && --state.activeLeases == 0) {
    FPDF_DestroyLibrary();
  }
  acquired_ = false;
}

std::unique_ptr<PdfiumLibrary> PdfiumLibrary::acquire(PdfiumError& error) {
  auto& state = libraryState();
  std::scoped_lock lock(state.lifecycleMutex, state.apiMutex);
  if (state.activeLeases == 0) {
    FPDF_LIBRARY_CONFIG config{};
    config.version = 2;
    FPDF_InitLibraryWithConfig(&config);
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
        pageCount(pageCount),
        ownerThread(std::this_thread::get_id()) {}

  std::unique_ptr<PdfiumLibrary> library;
  std::vector<std::uint8_t> documentBytes;
  FPDF_DOCUMENT document = nullptr;
  std::size_t pageCount = 0;
  std::thread::id ownerThread;
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
  assert(!impl_ || ownsWorkerThread());
  closeUnchecked();
  impl_ = std::move(other.impl_);
  return *this;
}

PdfiumDocumentSession::~PdfiumDocumentSession() {
  assert(!impl_ || ownsWorkerThread());
  closeUnchecked();
}

PdfiumOpenResult PdfiumDocumentSession::open(
    std::vector<std::uint8_t> documentBytes,
    std::string password) {
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

  PdfiumError libraryError;
  auto library = PdfiumLibrary::acquire(libraryError);
  if (!library) {
    result.error = libraryError.ok()
        ? PdfiumError{PdfiumErrorCode::LibraryInitializationFailed,
                      "Unable to initialize PDFium"}
        : libraryError;
    return result;
  }

  FPDF_DOCUMENT document = nullptr;
  unsigned long loadError = 0;
  {
    auto& state = libraryState();
    std::lock_guard apiLock(state.apiMutex);
    document = FPDF_LoadMemDocument(
        documentBytes.data(),
        static_cast<int>(documentBytes.size()),
        password.empty() ? nullptr : password.c_str());
    if (document == nullptr) loadError = FPDF_GetLastError();
  }
  if (document == nullptr) {
    result.error = {PdfiumErrorCode::DocumentOpenFailed,
                    "FPDF_LoadMemDocument failed (PDFium error " +
                        std::to_string(loadError) + ")"};
    return result;
  }

  std::size_t pageCount = 0;
  {
    auto& state = libraryState();
    std::lock_guard apiLock(state.apiMutex);
    const int count = FPDF_GetPageCount(document);
    if (count > 0) pageCount = static_cast<std::size_t>(count);
  }
  if (pageCount == 0) {
    auto& state = libraryState();
    std::lock_guard apiLock(state.apiMutex);
    FPDF_CloseDocument(document);
    result.error = {PdfiumErrorCode::DocumentOpenFailed,
                    "PDFium document contains no pages"};
    return result;
  }

  try {
    result.session = std::unique_ptr<PdfiumDocumentSession>(
        new PdfiumDocumentSession(std::move(library),
                                  std::move(documentBytes),
                                  document,
                                  pageCount));
    result.error = {};
  } catch (...) {
    auto& state = libraryState();
    std::lock_guard apiLock(state.apiMutex);
    FPDF_CloseDocument(document);
    result.error = {PdfiumErrorCode::DocumentOpenFailed,
                    "Unable to allocate the PDFium document session"};
  }
  return result;
}

std::size_t PdfiumDocumentSession::pageCount() const {
  assert(impl_ == nullptr || ownsWorkerThread());
  return impl_ ? impl_->pageCount : 0;
}

PdfiumError PdfiumDocumentSession::inspectPage(
    std::size_t pageIndex,
    PdfiumPageMetadata& metadata) const {
  if (!impl_) {
    return {PdfiumErrorCode::Closed, "PDFium document session is closed"};
  }
  if (!ownsWorkerThread()) {
    assert(false && "PDFium session used outside its creating worker");
    return {PdfiumErrorCode::WrongThread,
            "PDFium session must stay on its creating worker"};
  }
  if (pageIndex >= impl_->pageCount) {
    return {PdfiumErrorCode::InvalidPageIndex,
            "PDFium page index is outside the document"};
  }

  auto& state = libraryState();
  std::lock_guard apiLock(state.apiMutex);
  ScopedPage page(FPDF_LoadPage(impl_->document, static_cast<int>(pageIndex)));
  if (page.get() == nullptr) {
    const auto error = FPDF_GetLastError();
    return {PdfiumErrorCode::PageOpenFailed,
            "FPDF_LoadPage failed (PDFium error " + std::to_string(error) +
                ")"};
  }
  ScopedTextPage textPage(FPDFText_LoadPage(page.get()));
  if (textPage.get() == nullptr) {
    const auto error = FPDF_GetLastError();
    return {PdfiumErrorCode::TextPageOpenFailed,
            "FPDFText_LoadPage failed (PDFium error " +
                std::to_string(error) + ")"};
  }
  const int textCount = FPDFText_CountChars(textPage.get());
  if (textCount < 0) {
    const auto error = FPDF_GetLastError();
    return {PdfiumErrorCode::TextCountFailed,
            "FPDFText_CountChars failed (PDFium error " +
                std::to_string(error) + ")"};
  }

  const double width = FPDF_GetPageWidth(page.get());
  const double height = FPDF_GetPageHeight(page.get());
  if (!(width > 0.0) || !(height > 0.0)) {
    return {PdfiumErrorCode::PageOpenFailed,
            "PDFium page has invalid dimensions"};
  }
  metadata = {pageIndex, width, height, textCount};
  return {};
}

PdfiumError PdfiumDocumentSession::close() noexcept {
  if (!impl_) return {};
  if (!ownsWorkerThread()) {
    assert(false && "PDFium session closed outside its creating worker");
    return {PdfiumErrorCode::WrongThread,
            "PDFium session must close on its creating worker"};
  }
  closeUnchecked();
  return {};
}

bool PdfiumDocumentSession::ownsWorkerThread() const {
  return impl_ != nullptr &&
      impl_->ownerThread == std::this_thread::get_id();
}

void PdfiumDocumentSession::closeUnchecked() noexcept {
  if (!impl_) return;
  if (!ownsWorkerThread()) return;

  if (impl_->document != nullptr) {
    auto& state = libraryState();
    {
      std::lock_guard apiLock(state.apiMutex);
      FPDF_CloseDocument(impl_->document);
    }
    impl_->document = nullptr;
  }
  impl_.reset();
}

}  // namespace margelo::nitro::inksignpdf::pdfium
