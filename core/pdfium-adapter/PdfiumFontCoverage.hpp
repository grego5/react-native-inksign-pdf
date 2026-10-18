#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace margelo::nitro::inksignpdf::pdfium {

struct FontResource final {
  std::string source;
  std::size_t collectionIndex = 0;
  std::shared_ptr<const std::vector<std::uint8_t>> bytes;
};

std::shared_ptr<FontResource> loadFontResource(
    std::string source,
    std::vector<std::uint8_t> bytes,
    std::size_t collectionIndex,
    std::string* errorMessage);

}  // namespace margelo::nitro::inksignpdf::pdfium
