#include "pdfium-adapter/PdfiumFontFallback.hpp"
#include "pdfium-adapter/PdfiumFontCoverage.hpp"

#include <memory>
#include <string_view>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

class FontSubstitutionRegistryImpl final {
 public:
  bool setSuppliedFont(const std::string& path,
                       std::size_t collectionIndex,
                       std::string* errorMessage) {
    supplied_ = loadFontResource(path, collectionIndex, errorMessage);
    return supplied_ != nullptr;
  }

  std::shared_ptr<const FontResource> fallbackFont() const {
    return supplied_;
  }

 private:
  std::shared_ptr<FontResource> supplied_;
};

thread_local FontSubstitutionRegistry* activeFontRegistry = nullptr;

}  // namespace

FontSubstitutionRegistry::FontSubstitutionRegistry()
    : impl_(std::make_shared<FontSubstitutionRegistryImpl>()) {}

FontSubstitutionRegistry::~FontSubstitutionRegistry() = default;

bool FontSubstitutionRegistry::setSuppliedFont(
    const std::string& path,
    std::size_t collectionIndex,
    std::string* errorMessage) {
  auto implementation =
      std::static_pointer_cast<FontSubstitutionRegistryImpl>(impl_);
  return implementation->setSuppliedFont(path, collectionIndex, errorMessage);
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
  const auto resource = implementation->fallbackFont();
  if (resource == nullptr) return nullptr;
  return std::make_shared<PdfiumResolvedFont>(
      PdfiumResolvedFont{resource->selection.path,
                         resource->selection.collectionIndex,
                         resource->bytes});
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
