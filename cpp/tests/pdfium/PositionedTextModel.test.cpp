#include "tests/support/TestSupport.hpp"
#include "pdfium/PositionedTextModel.hpp"

#include <memory>
#include <vector>

using namespace margelo::nitro::inksignpdf::pdfium;

int main() {
  PositionedCharacter character;
  character.sourceIndex = 7;
  character.textObjectOrdinal = 3;
  character.unicode = 0x41;
  character.origin = {12.0, 24.0};
  character.bounds = {10.0, 14.0, 18.0, 26.0};
  character.nextDisplacement = Point{8.0, 0.0};

  auto page = std::make_shared<const PositionedPage>(
      2, Rect{0.0, 0.0, 612.0, 792.0}, std::vector{character});
  PositionedPageResult result{19, 2, page};

  CHECK(result.valid());
  CHECK(result.generation == 19);
  CHECK(result.pageIndex == 2);
  CHECK(result.page->pageIndex() == 2);
  CHECK(result.page->characters().size() == 1);
  CHECK(result.page->characters().front().unicode == 0x41);
  CHECK(result.page->characters().front().nextDisplacement->x == 8.0);

  const PositionedPageSnapshot detached = result.page;
  result.page.reset();
  CHECK(detached->characters().front().sourceIndex == 7);
  CHECK(detached->pageBounds().bottom == 792.0);
  return 0;
}
