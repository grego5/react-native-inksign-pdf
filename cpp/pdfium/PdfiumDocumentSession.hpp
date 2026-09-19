#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

enum class PdfiumErrorCode : std::uint8_t {
  None,
  InvalidInput,
  LibraryInitializationFailed,
  DocumentOpenFailed,
  Closed,
  WrongThread,
  InvalidPageIndex,
  PageOpenFailed,
  TextPageOpenFailed,
  TextCountFailed,
};

struct PdfiumError final {
  PdfiumErrorCode code = PdfiumErrorCode::None;
  std::string message;

  bool ok() const { return code == PdfiumErrorCode::None; }
  explicit operator bool() const { return ok(); }
};

class PdfiumLibrary final {
 public:
  PdfiumLibrary() = delete;
  PdfiumLibrary(const PdfiumLibrary&) = delete;
  PdfiumLibrary& operator=(const PdfiumLibrary&) = delete;
  PdfiumLibrary(PdfiumLibrary&& other) noexcept;
  PdfiumLibrary& operator=(PdfiumLibrary&& other) noexcept;
  ~PdfiumLibrary();

  static std::unique_ptr<PdfiumLibrary> acquire(PdfiumError& error);

 private:
  explicit PdfiumLibrary(bool acquired) : acquired_(acquired) {}

  bool acquired_ = false;
};

/** Metadata that can be read while a page and its temporary text page exist. */
struct PdfiumPageMetadata final {
  std::size_t pageIndex = 0;
  double width = 0.0;
  double height = 0.0;
  std::int32_t textCharacterCount = 0;
};

struct PdfiumOpenResult final {
  std::unique_ptr<class PdfiumDocumentSession> session;
  PdfiumError error;

  bool ok() const { return session != nullptr && error.ok(); }
  explicit operator bool() const { return ok(); }
};

/**
 * A move-only PDFium document owner. All methods and destruction are required
 * to stay on the serial worker thread that created the session.
 */
class PdfiumDocumentSession final {
 public:
  PdfiumDocumentSession(const PdfiumDocumentSession&) = delete;
  PdfiumDocumentSession& operator=(const PdfiumDocumentSession&) = delete;
  PdfiumDocumentSession(PdfiumDocumentSession&& other) noexcept;
  PdfiumDocumentSession& operator=(PdfiumDocumentSession&& other) noexcept;
  ~PdfiumDocumentSession();

  static PdfiumOpenResult open(std::vector<std::uint8_t> documentBytes,
                               std::string password = {});

  std::size_t pageCount() const;
  PdfiumError inspectPage(std::size_t pageIndex,
                          PdfiumPageMetadata& metadata) const;
  PdfiumError close() noexcept;

 private:
  struct Impl;

  PdfiumDocumentSession(std::unique_ptr<PdfiumLibrary> library,
                        std::vector<std::uint8_t> documentBytes,
                        void* document,
                        std::size_t pageCount);

  bool ownsWorkerThread() const;
  void closeUnchecked() noexcept;

  std::unique_ptr<Impl> impl_;
};

}  // namespace margelo::nitro::inksignpdf::pdfium
