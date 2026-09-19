#include "pdfium/PositionedTextModel.hpp"

#include <stdexcept>
#include <utility>

namespace margelo::nitro::inksignpdf::pdfium {

PositionedPage::PositionedPage(
    std::int32_t pageIndex,
    Rect pageBounds,
    std::vector<PositionedCharacter> characters)
    : storage_(std::make_shared<const Storage>(Storage{
          pageIndex, pageBounds, std::move(characters)})) {
  if (pageIndex < 0) {
    throw std::invalid_argument("positioned page index must be non-negative");
  }
}

}  // namespace margelo::nitro::inksignpdf::pdfium
