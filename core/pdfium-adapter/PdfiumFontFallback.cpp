#include "pdfium-adapter/PdfiumFontFallback.hpp"
#include "pdfium-adapter/PdfiumFontCoverage.hpp"

#include <memory>
#include <string_view>
#include <utility>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

class FontSubstitutionRegistryImpl final {
 public:
  bool setSuppliedFont(std::string source,
                       std::vector<std::uint8_t> bytes,
                       std::size_t collectionIndex,
                       std::string* errorMessage) {
    auto resource = loadFontResource(
        std::move(source), std::move(bytes), collectionIndex, errorMessage);
    if (resource == nullptr) {
      supplied_.reset();
      return false;
    }
    supplied_ = std::make_shared<const PdfiumResolvedFont>(
        PdfiumResolvedFont{std::move(resource->source), resource->collectionIndex,
                          std::move(resource->bytes)});
    return true;
  }

  std::shared_ptr<const PdfiumResolvedFont> fallbackFont() const {
    return supplied_;
  }

 private:
  std::shared_ptr<const PdfiumResolvedFont> supplied_;
};

thread_local FontSubstitutionRegistry* activeFontRegistry = nullptr;

}  // namespace

FontSubstitutionRegistry::FontSubstitutionRegistry()
    : impl_(std::make_shared<FontSubstitutionRegistryImpl>()) {}

FontSubstitutionRegistry::~FontSubstitutionRegistry() = default;

bool FontSubstitutionRegistry::setSuppliedFont(
    std::string source,
    std::vector<std::uint8_t> bytes,
    std::size_t collectionIndex,
    std::string* errorMessage) {
  auto implementation =
      std::static_pointer_cast<FontSubstitutionRegistryImpl>(impl_);
  return implementation->setSuppliedFont(std::move(source), std::move(bytes), collectionIndex, errorMessage);
}

std::shared_ptr<const PdfiumResolvedFont> FontSubstitutionRegistry::resolveFont(
    std::string_view face,
    int weight,
    FPDF_BOOL italic) const {
  auto implementation =
      std::static_pointer_cast<FontSubstitutionRegistryImpl>(impl_);
  (void)face;
  (void)weight;
  (void)italic;
  return implementation->fallbackFont();
}

ScopedFontRegistry::ScopedFontRegistry(FontSubstitutionRegistry* registry)
    : previous_(activeFontRegistry) {
  activeFontRegistry = registry;
}

ScopedFontRegistry::~ScopedFontRegistry() {
  activeFontRegistry = previous_;
}

std::shared_ptr<const PdfiumResolvedFont> resolveActiveFont(
    const char* face,
    int weight,
    FPDF_BOOL italic) {
  if (activeFontRegistry == nullptr) return nullptr;
  return activeFontRegistry->resolveFont(face, weight, italic);
}

}  // namespace margelo::nitro::inksignpdf::pdfium
