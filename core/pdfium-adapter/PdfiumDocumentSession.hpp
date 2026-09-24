#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

enum class PdfiumErrorCode : std::uint8_t {
  None,
  InvalidInput,
  LibraryInitializationFailed,
  DocumentOpenFailed,
  Closed,
  InvalidPageIndex,
  PageOpenFailed,
  InvalidFallbackFont,
  LastPageRequired,
  InvalidAssemblyCommand,
  SourceDocumentOpenFailed,
  MutationFailed,
  SaveFailed,
  ValidationFailed,
  UnsupportedText,
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
  // Page dimensions as exposed by PDFium for the rotated display page.
  double width = 0.0;
  double height = 0.0;
  // PDFium quarter-turn value: 0, 1, 2, or 3.
  int rotation = 0;
  // Unrotated PDF MediaBox in PDF user-space coordinates.
  double mediaBoxLeft = 0.0;
  double mediaBoxBottom = 0.0;
  double mediaBoxRight = 0.0;
  double mediaBoxTop = 0.0;

  double canonicalWidth() const { return mediaBoxRight - mediaBoxLeft; }
  double canonicalHeight() const { return mediaBoxTop - mediaBoxBottom; }
};

struct PdfiumRenderRect final {
  double left = 0.0;
  double top = 0.0;
  double right = 0.0;
  double bottom = 0.0;
};

struct PdfiumRenderMatrix final {
  double a = 1.0;
  double b = 0.0;
  double c = 0.0;
  double d = 1.0;
  double e = 0.0;
  double f = 0.0;
};

struct PdfiumOpenResult final {
  std::unique_ptr<class PdfiumDocumentSession> session;
  PdfiumError error;

  bool ok() const { return session != nullptr && error.ok(); }
  explicit operator bool() const { return ok(); }
};

/** Caller-owned device buffer and transform for one PDFium page render. */
struct PdfiumPageRenderRequest final {
  std::size_t pageIndex = 0;
  std::int32_t width = 0;
  std::int32_t height = 0;
  std::int32_t stride = 0;
  PdfiumRenderMatrix pageToDevice;
  PdfiumRenderRect clip;
  std::uint32_t background = 0xFFFFFFFFu;
  std::uint32_t flags = 0;
  std::span<std::uint8_t> bgra;
};

struct PdfiumFallbackFont final {
  std::string path;
  std::size_t collectionIndex = 0;
};

/**
 * A move-only PDFium document owner. The caller must serialize all methods,
 * moves, and destruction on one owned execution context. That context may be a
 * dedicated thread or a serial queue; no OS-thread affinity is required.
 */
class PdfiumDocumentSession final {
 public:
  PdfiumDocumentSession(const PdfiumDocumentSession&) = delete;
  PdfiumDocumentSession& operator=(const PdfiumDocumentSession&) = delete;
  PdfiumDocumentSession(PdfiumDocumentSession&& other) noexcept;
  PdfiumDocumentSession& operator=(PdfiumDocumentSession&& other) noexcept;
  ~PdfiumDocumentSession();

  static PdfiumOpenResult open(std::vector<std::uint8_t> documentBytes,
                               std::string password = {},
                               std::optional<PdfiumFallbackFont> fallbackFont =
                                   std::nullopt);

  std::size_t pageCount() const;
  PdfiumError inspectPage(std::size_t pageIndex,
                          PdfiumPageMetadata& metadata) const;
  PdfiumError renderPage(const PdfiumPageRenderRequest& request) const;
  PdfiumError close() noexcept;

 private:
  struct Impl;

  PdfiumDocumentSession(std::unique_ptr<PdfiumLibrary> library,
                        std::vector<std::uint8_t> documentBytes,
                        void* document,
                        std::size_t pageCount);

  void closeUnchecked() noexcept;

  std::unique_ptr<Impl> impl_;
};

}  // namespace margelo::nitro::inksignpdf::pdfium
