#include "pdfium/PositionedTextDiagnostics.hpp"

#include <algorithm>
#include <iomanip>
#include <sstream>

namespace margelo::nitro::inksignpdf::pdfium {

std::string dumpPositionedPageDiagnostics(const PositionedPage& page,
                                          std::size_t maxCharacters) {
#if defined(NDEBUG)
  static_cast<void>(page);
  static_cast<void>(maxCharacters);
  return {};
#else
  constexpr std::size_t kHardCharacterLimit = 128;
  const auto characters = page.characters();
  const std::size_t count = std::min(
      {maxCharacters, kHardCharacterLimit, characters.size()});

  std::ostringstream output;
  output << "page=" << page.pageIndex() << " chars=" << characters.size()
         << " shown=" << count << '\n';
  output << std::setprecision(6);
  for (std::size_t index = 0; index < count; ++index) {
    const auto& character = characters[index];
    output << "[" << index << "] source=" << character.sourceIndex
           << " cp=U+" << std::uppercase << std::hex << character.unicode
           << std::dec << std::nouppercase
           << " object=" << character.textObjectOrdinal
           << " generated=" << (character.generated ? 1 : 0)
           << " mapError=" << (character.unicodeMapError ? 1 : 0)
           << " font=\"" << character.font.family << "\""
           << " flags=" << character.font.flags
           << " weight=" << character.font.weight
           << " renderMode=" << static_cast<int>(character.renderMode)
           << " fill=";
    if (character.fillColor) {
      output << '(' << static_cast<int>(character.fillColor->red) << ','
             << static_cast<int>(character.fillColor->green) << ','
             << static_cast<int>(character.fillColor->blue) << ','
             << static_cast<int>(character.fillColor->alpha) << ')';
    } else {
      output << "absent";
    }
    output << " stroke=";
    if (character.strokeColor) {
      output << '(' << static_cast<int>(character.strokeColor->red) << ','
             << static_cast<int>(character.strokeColor->green) << ','
             << static_cast<int>(character.strokeColor->blue) << ','
             << static_cast<int>(character.strokeColor->alpha) << ')';
    } else {
      output << "absent";
    }
    output << " origin=(" << character.origin.x << ',' << character.origin.y
           << ") bounds=(" << character.bounds.left << ','
           << character.bounds.top << ',' << character.bounds.right << ','
           << character.bounds.bottom << ") matrix=(" << character.matrix.a
           << ',' << character.matrix.b << ',' << character.matrix.c << ','
           << character.matrix.d << ',' << character.matrix.e << ','
           << character.matrix.f << ") fontSize=" << character.fontSize
           << " displacement=";
    if (character.nextDisplacement) {
      output << '(' << character.nextDisplacement->x << ','
             << character.nextDisplacement->y << ')';
    } else {
      output << "absent";
    }
    output << '\n';
  }
  if (count < characters.size()) output << "... truncated\n";
  return output.str();
#endif
}

}  // namespace margelo::nitro::inksignpdf::pdfium
