#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

struct FontSelection final {
  std::string path;
  std::size_t collectionIndex = 0;
};

struct FontResource final {
  FontSelection selection;
  std::shared_ptr<const std::vector<std::uint8_t>> bytes;
};

std::shared_ptr<FontResource> loadFontResource(
    const std::string& path,
    std::size_t collectionIndex,
    std::string* errorMessage);

}  // namespace margelo::nitro::inksignpdf::pdfium
