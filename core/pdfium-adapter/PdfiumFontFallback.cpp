#include "pdfium-adapter/PdfiumFontFallback.hpp"
#include "pdfium-adapter/PdfiumFontCoverage.hpp"

#include <fpdf_edit.h>
#include <fpdf_sysfontinfo.h>
#include <fpdf_text.h>
#include <fpdfview.h>

#include <memory>
#include <string_view>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {

class FontScopedPage final {
 public:
  explicit FontScopedPage(FPDF_PAGE page) : page_(page) {}
  FontScopedPage(const FontScopedPage&) = delete;
  FontScopedPage& operator=(const FontScopedPage&) = delete;
  ~FontScopedPage() {
    if (page_ != nullptr) FPDF_ClosePage(page_);
  }
  FPDF_PAGE get() const { return page_; }
 private:
  FPDF_PAGE page_ = nullptr;
};

class FontSubstitutionRegistryImpl final {
 public:
  void require() { hasNonEmbeddedFont_ = true; }

  bool setSuppliedFont(const std::string& path,
                       std::size_t collectionIndex,
                       std::string* errorMessage) {
    supplied_ = loadFontResource(path, collectionIndex, errorMessage);
    return supplied_ != nullptr;
  }

  void resolve() {
    resolved_ = true;
  }

  std::shared_ptr<const FontResource> fallbackFont() const {
    return resolved_ && hasNonEmbeddedFont_ ? supplied_ : nullptr;
  }

 private:
  std::shared_ptr<FontResource> supplied_;
  bool hasNonEmbeddedFont_ = false;
  bool resolved_ = false;
};

thread_local FontSubstitutionRegistry* activeFontRegistry = nullptr;

}  // namespace

FontSubstitutionRegistry::FontSubstitutionRegistry()
    : impl_(std::make_shared<FontSubstitutionRegistryImpl>()) {}

FontSubstitutionRegistry::~FontSubstitutionRegistry() = default;

void FontSubstitutionRegistry::require() {
  auto implementation =
      std::static_pointer_cast<FontSubstitutionRegistryImpl>(impl_);
  implementation->require();
}

bool FontSubstitutionRegistry::setSuppliedFont(
    const std::string& path,
    std::size_t collectionIndex,
    std::string* errorMessage) {
  auto implementation =
      std::static_pointer_cast<FontSubstitutionRegistryImpl>(impl_);
  return implementation->setSuppliedFont(path, collectionIndex, errorMessage);
}

void FontSubstitutionRegistry::resolve() {
  auto implementation =
      std::static_pointer_cast<FontSubstitutionRegistryImpl>(impl_);
  implementation->resolve();
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

namespace {

class FontScopedTextPage final {
 public:
  explicit FontScopedTextPage(FPDF_TEXTPAGE page) : page_(page) {}
  FontScopedTextPage(const FontScopedTextPage&) = delete;
  FontScopedTextPage& operator=(const FontScopedTextPage&) = delete;
  ~FontScopedTextPage() {
    if (page_ != nullptr) FPDFText_ClosePage(page_);
  }

  FPDF_TEXTPAGE get() const { return page_; }

 private:
  FPDF_TEXTPAGE page_ = nullptr;
};

void collectFontRequirementsImpl(FPDF_DOCUMENT document,
                                 std::size_t pageCount,
                                 FontSubstitutionRegistry& registry) {
  for (std::size_t pageIndex = 0; pageIndex < pageCount; ++pageIndex) {
    FontScopedPage page(FPDF_LoadPage(document, static_cast<int>(pageIndex)));
    if (page.get() == nullptr) continue;
    FontScopedTextPage textPage(FPDFText_LoadPage(page.get()));
    if (textPage.get() == nullptr) continue;
    const int characterCount = FPDFText_CountChars(textPage.get());
    if (characterCount <= 0) continue;

    for (int characterIndex = 0; characterIndex < characterCount;
         ++characterIndex) {
      const auto textObject =
          FPDFText_GetTextObject(textPage.get(), characterIndex);
      if (textObject == nullptr) continue;
      const auto font = FPDFTextObj_GetFont(textObject);
      if (font == nullptr || FPDFFont_GetIsEmbedded(font) == 1) continue;
      registry.require();
      return;
    }
  }
}


}  // namespace

void collectFontRequirements(FPDF_DOCUMENT document,
                             std::size_t pageCount,
                             FontSubstitutionRegistry& registry) {
  collectFontRequirementsImpl(document, pageCount, registry);
}

}  // namespace margelo::nitro::inksignpdf::pdfium
