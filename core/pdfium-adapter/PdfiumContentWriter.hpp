#pragma once

#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include <functional>
#include <array>

namespace margelo::nitro::inksignpdf::pdfium {

struct PdfiumPositionedGlyph final {
  std::uint32_t sourceOffset = 0;
  std::size_t order = 0;
  std::uint32_t glyphId = 0;
  std::u16string unicode;
  float x = 0;
  float y = 0;
};

struct PdfiumShapedRun final {
  std::vector<PdfiumPositionedGlyph> glyphs;
  float advance = 0;
  std::string error;
  // CoreText supplies final layout-local positions/baselines. Android supplies
  // relative run positions, which the writer places using its line alignment.
  bool prepositioned = false;
};

using PdfiumTextShaper = std::function<PdfiumShapedRun(
    std::size_t, std::span<const std::uint8_t>, std::u16string_view, bool, float)>;

/** Owned compact export buffers. Index/range units are UTF-16; transforms are
 * saved layout-to-canonical matrices. No platform object escapes into the writer.
 */
struct PdfiumContentInput final {
  std::vector<std::int32_t> pageIndices, pageRotations;
  std::vector<double> pageDimensions;
  std::vector<std::int32_t> pathPageIndices, pathCommandOffsets, pathCommandTypes;
  std::vector<float> pathCoordinates;
  std::vector<std::int32_t> pathColors;
  std::vector<std::int32_t> textRunPageIndices, textRunLineIds;
  std::vector<std::u16string> textRunTexts;
  std::vector<std::int32_t> textRunSourceRanges, textRunBidiLevels, textRunVisualOrder;
  std::vector<std::int32_t> textRunBaseDirections, textRunAlignments, textRunFontIndices;
  std::vector<float> textRunGeometry, textRunTransforms;
  // Optional per-run layout-local hard bounds: left, top, right, bottom.
  std::vector<std::optional<std::array<float, 4>>> textRunClips;
  std::vector<std::int32_t> textRunColors, explicitFontSelections;
  std::vector<std::vector<std::uint8_t>> fontResources;
  bool maySubsetFonts = true;
  bool forceSubsetSaveFailureForTesting = false;
  std::int32_t inkColor = static_cast<std::int32_t>(0xFF000000u);
};

class PdfiumContentWriter final {
 public:
  static PdfiumError write(const std::vector<std::uint8_t>& sourceBytes,
                           const PdfiumContentInput& input,
                           const PdfiumTextShaper& shapeText,
                           std::vector<std::uint8_t>& outputBytes);
};

}  // namespace margelo::nitro::inksignpdf::pdfium
