#pragma once

#include <fpdfview.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

struct PdfiumResolvedFont final {
  std::string path;
  std::size_t collectionIndex = 0;
  std::shared_ptr<const std::vector<std::uint8_t>> bytes;
};

class FontSubstitutionRegistry final {
 public:
  FontSubstitutionRegistry();
  ~FontSubstitutionRegistry();

  FontSubstitutionRegistry(const FontSubstitutionRegistry&) = delete;
  FontSubstitutionRegistry& operator=(const FontSubstitutionRegistry&) = delete;

  bool setSuppliedFont(const std::string& path,
                       std::size_t collectionIndex,
                       std::string* errorMessage);

  std::shared_ptr<const PdfiumResolvedFont> resolveFont(
      std::string_view face,
      int weight,
      FPDF_BOOL italic) const;

 private:
  std::shared_ptr<void> impl_;
};

std::shared_ptr<const PdfiumResolvedFont> resolveActiveFont(
    const char* face,
    int weight,
    FPDF_BOOL italic);

class ScopedFontRegistry final {
 public:
  explicit ScopedFontRegistry(FontSubstitutionRegistry* registry);
  ScopedFontRegistry(const ScopedFontRegistry&) = delete;
  ScopedFontRegistry& operator=(const ScopedFontRegistry&) = delete;
  ~ScopedFontRegistry();

 private:
  FontSubstitutionRegistry* previous_ = nullptr;
};

bool installSystemFontProvider();
void uninstallSystemFontProvider();

}  // namespace margelo::nitro::inksignpdf::pdfium
