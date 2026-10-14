#include "pdfium-adapter/PdfiumPageGeometry.hpp"
#include "pdfium-adapter/PdfiumContentWriter.hpp"
#include "pdfium-adapter/PdfiumLibraryInternal.hpp"
#include <fpdf_edit.h>
#include <fpdf_save.h>
#include <fpdf_ppo.h>
#include <fpdf_transformpage.h>
#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <utility>

namespace margelo::nitro::inksignpdf::pdfium {
namespace {
struct VectorFileWriter final {
  FPDF_FILEWRITE api{1, writeBlock};
  std::vector<std::uint8_t> bytes;

  static int FPDF_CALLCONV writeBlock(FPDF_FILEWRITE* self,
                                      const void* data,
                                      unsigned long size) {
    auto* writer = reinterpret_cast<VectorFileWriter*>(self);
    if (size > static_cast<unsigned long>(
                   (std::numeric_limits<std::size_t>::max)() - writer->bytes.size())) {
      return 0;
    }
    const auto* source = static_cast<const std::uint8_t*>(data);
    writer->bytes.insert(writer->bytes.end(), source, source + size);
    return 1;
  }
};

class ScopedDocument final {
 public:
  explicit ScopedDocument(FPDF_DOCUMENT value) : value_(value) {}
  ScopedDocument(const ScopedDocument&) = delete;
  ScopedDocument& operator=(const ScopedDocument&) = delete;
  ~ScopedDocument() {
    if (value_ != nullptr) FPDF_CloseDocument(value_);
  }
  FPDF_DOCUMENT get() const { return value_; }

 private:
  FPDF_DOCUMENT value_ = nullptr;
};

class ScopedFont final {
 public:
  explicit ScopedFont(FPDF_FONT value) : value_(value) {}
  ScopedFont(const ScopedFont&) = delete;
  ScopedFont& operator=(const ScopedFont&) = delete;
  ~ScopedFont() {
    if (value_ != nullptr) FPDFFont_Close(value_);
  }
  FPDF_FONT get() const { return value_; }

 private:
  FPDF_FONT value_ = nullptr;
};

class ScopedPage final {
 public:
  explicit ScopedPage(FPDF_PAGE value) : value_(value) {}
  ScopedPage(const ScopedPage&) = delete;
  ScopedPage& operator=(const ScopedPage&) = delete;
  ~ScopedPage() {
    if (value_ != nullptr) FPDF_ClosePage(value_);
  }
  FPDF_PAGE get() const { return value_; }

 private:
  FPDF_PAGE value_ = nullptr;
};

class ScopedPageObject final {
 public:
  explicit ScopedPageObject(FPDF_PAGEOBJECT value) : value_(value) {}
  ScopedPageObject(const ScopedPageObject&) = delete;
  ScopedPageObject& operator=(const ScopedPageObject&) = delete;
  ~ScopedPageObject() {
    if (value_ != nullptr) FPDFPageObj_Destroy(value_);
  }
  FPDF_PAGEOBJECT get() const { return value_; }
  FPDF_PAGEOBJECT release() {
    auto* value = value_;
    value_ = nullptr;
    return value;
  }

 private:
  FPDF_PAGEOBJECT value_ = nullptr;
};

struct ShapedGlyph final {
  std::size_t runIndex;
  std::uint32_t sourceCluster;
  std::size_t outputOrder;
  int fontIndex;
  std::uint32_t glyphId;
  std::u16string unicode;
  float x;
  float baselineFromTop;
  float fontSize;
  std::int32_t color;
  float horizontalScale = 1.0f;
  std::uint16_t cid = 0;
};

struct ShapedSegment final {
  std::size_t runIndex;
  std::size_t sourceStart;
  std::size_t sourceLength;
  int fontIndex;
  float originX;
  float baselineFromTop;
  float fontSize;
  float advance;
  std::int32_t color;
  std::vector<ShapedGlyph> glyphs;
  bool prepositioned = false;
};

struct TextPlacement final {
  int pageIndex;
  float fontSize;
  FS_MATRIX matrix;
};

std::string hex16(std::uint16_t value) {
  static constexpr char digits[] = "0123456789ABCDEF";
  std::string result(4, '0');
  for (int index = 3; index >= 0; --index) {
    result[static_cast<std::size_t>(index)] = digits[value & 0xF];
    value = static_cast<std::uint16_t>(value >> 4);
  }
  return result;
}

std::string hexUnicode(const std::u16string& value) {
  static constexpr char digits[] = "0123456789ABCDEF";
  std::string result = "<";
  result.reserve(value.size() * 4 + 2);
  for (char16_t character : value) {
    const auto unit = static_cast<std::uint16_t>(character);
    result.push_back(digits[(unit >> 12) & 0xF]);
    result.push_back(digits[(unit >> 8) & 0xF]);
    result.push_back(digits[(unit >> 4) & 0xF]);
    result.push_back(digits[unit & 0xF]);
  }
  result.push_back('>');
  return result;
}

std::string buildToUnicodeCMap(
    const std::map<std::uint16_t, std::u16string>& mappings) {
  std::string cmap =
      "/CIDInit /ProcSet findresource begin\n"
      "12 dict begin\n"
      "begincmap\n"
      "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
      "/CMapName /Adobe-Identity-UCS def\n"
      "/CMapType 2 def\n"
      "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n";
  auto entry = mappings.begin();
  while (entry != mappings.end()) {
    const auto remaining = static_cast<std::size_t>(std::distance(entry, mappings.end()));
    const auto blockSize = (std::min)(remaining, static_cast<std::size_t>(100));
    cmap += std::to_string(blockSize) + " beginbfchar\n";
    for (std::size_t index = 0; index < blockSize; ++index, ++entry) {
      const auto destination = entry->second.empty()
          ? std::u16string(1, u'\uFEFF')
          : entry->second;
      cmap += "<" + hex16(entry->first) + "> " + hexUnicode(destination) + "\n";
    }
    cmap += "endbfchar\n";
  }
  cmap +=
      "endcmap\n"
      "CMapName currentdict /CMap defineresource pop\n"
      "end\n"
      "end\n";
  return cmap;
}

FS_MATRIX compose(const FS_MATRIX& parent, const FS_MATRIX& child) {
  return {parent.a * child.a + parent.c * child.b,
          parent.b * child.a + parent.d * child.b,
          parent.a * child.c + parent.c * child.d,
          parent.b * child.c + parent.d * child.d,
          parent.a * child.e + parent.c * child.f + parent.e,
          parent.b * child.e + parent.d * child.f + parent.f};
}

struct LeafObject final {
  FPDF_PAGEOBJECT object;
  FS_MATRIX parent;
};

bool collectObject(FPDF_PAGEOBJECT object, const FS_MATRIX& parent,
                   std::vector<LeafObject>& leaves, unsigned depth) {
  if (object == nullptr || depth > 64) return false;
  if (FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_FORM) {
    leaves.push_back({object, parent});
    return true;
  }
  FS_MATRIX matrix{};
  if (!FPDFPageObj_GetMatrix(object, &matrix)) return false;
  const auto combined = compose(parent, matrix);
  const int count = FPDFFormObj_CountObjects(object);
  if (count < 0) return false;
  for (int index = 0; index < count; ++index)
    if (!collectObject(FPDFFormObj_GetObject(object, index), combined, leaves, depth + 1))
      return false;
  return true;
}

bool pageLeaves(FPDF_PAGE page, std::vector<LeafObject>& leaves) {
  const int count = FPDFPage_CountObjects(page);
  if (count < 0) return false;
  for (int index = 0; index < count; ++index)
    if (!collectObject(FPDFPage_GetObject(page, index), {1, 0, 0, 1, 0, 0}, leaves, 0))
      return false;
  return true;
}

bool objectCounts(FPDF_PAGE page, int& paths, int& texts) {
  paths = 0;
  texts = 0;
  std::vector<LeafObject> leaves;
  if (!pageLeaves(page, leaves)) return false;
  for (const auto& leaf : leaves) {
    const auto type = FPDFPageObj_GetType(leaf.object);
    if (type == FPDF_PAGEOBJ_PATH) ++paths;
    if (type == FPDF_PAGEOBJ_TEXT) ++texts;
  }
  return true;
}

bool near(double actual, double expected) {
  return std::isfinite(actual) && std::isfinite(expected) &&
         std::abs(actual - expected) <= 0.05;
}

bool dimensionsMatch(FPDF_PAGE page, double width, double height) {
  return near(FPDF_GetPageWidthF(page), width) && near(FPDF_GetPageHeightF(page), height);
}

bool preciseNear(double actual, double expected) {
  return std::isfinite(actual) && std::isfinite(expected) &&
         std::abs(actual - expected) <= 0.001;
}

float pathCoordinate(const std::vector<float>& coordinates,
                     int commandIndex,
                     int slot) {
  return coordinates[static_cast<std::size_t>(commandIndex) * 6 + slot];
}

bool pathMatchesExpected(FPDF_PAGEOBJECT object,
                         int begin,
                         int end,
                         const std::vector<std::int32_t>& commandTypes,
                         const std::vector<float>& coordinates,
                         double visibleBoxLeft,
                         double visibleBoxTop,
                         std::string& mismatch) {
  const auto expectedCoordinate = [&](int commandIndex, int slot) {
    const float value = pathCoordinate(coordinates, commandIndex, slot);
    if (slot == 1 || slot == 3 || slot == 5) {
      return static_cast<float>(visibleBoxTop - value);
    }
    return static_cast<float>(visibleBoxLeft + value);
  };
  struct ExpectedSegment {
    int type;
    float x;
    float y;
  };
  std::vector<ExpectedSegment> expectedSegments;
  float startX = 0;
  float startY = 0;
  float currentX = 0;
  float currentY = 0;
  bool hasCurrentPoint = false;
  bool expectedClose = false;
  for (int commandIndex = begin; commandIndex < end; ++commandIndex) {
    const int commandType = commandTypes[commandIndex];
    if (commandType == 0) {
      startX = currentX = expectedCoordinate(commandIndex, 0);
      startY = currentY = expectedCoordinate(commandIndex, 1);
      hasCurrentPoint = true;
      expectedSegments.push_back({FPDF_SEGMENT_MOVETO, currentX, currentY});
    } else if (commandType == 1) {
      currentX = expectedCoordinate(commandIndex, 0);
      currentY = expectedCoordinate(commandIndex, 1);
      expectedSegments.push_back({FPDF_SEGMENT_LINETO, currentX, currentY});
    } else if (commandType == 2) {
      expectedSegments.push_back({FPDF_SEGMENT_BEZIERTO,
          expectedCoordinate(commandIndex, 2),
          expectedCoordinate(commandIndex, 3)});
      expectedSegments.push_back({FPDF_SEGMENT_BEZIERTO,
          expectedCoordinate(commandIndex, 4),
          expectedCoordinate(commandIndex, 5)});
      currentX = expectedCoordinate(commandIndex, 0);
      currentY = expectedCoordinate(commandIndex, 1);
      expectedSegments.push_back({FPDF_SEGMENT_BEZIERTO, currentX, currentY});
    } else if (commandType == 3) {
      expectedClose = true;
      if (hasCurrentPoint && (!preciseNear(currentX, startX) || !preciseNear(currentY, startY))) {
        expectedSegments.push_back({FPDF_SEGMENT_LINETO, startX, startY});
      }
      currentX = startX;
      currentY = startY;
    }
  }
  const int expectedSegmentCount = static_cast<int>(expectedSegments.size());
  const int actualSegmentCount = FPDFPath_CountSegments(object);
  if (actualSegmentCount != expectedSegmentCount) {
    mismatch = "segment count expected " + std::to_string(expectedSegmentCount) +
        ", got " + std::to_string(actualSegmentCount);
    return false;
  }

  for (int segmentIndex = 0; segmentIndex < expectedSegmentCount; ++segmentIndex) {
    auto segment = FPDFPath_GetPathSegment(object, segmentIndex);
    if (segment == nullptr) {
      mismatch = "missing path segment " + std::to_string(segmentIndex);
      return false;
    }
    float x = 0;
    float y = 0;
    if (FPDFPathSegment_GetType(segment) != expectedSegments[segmentIndex].type) {
      mismatch = "segment " + std::to_string(segmentIndex) + " type differs";
      return false;
    }
    if (!FPDFPathSegment_GetPoint(segment, &x, &y)) {
      mismatch = "segment " + std::to_string(segmentIndex) + " has no point";
      return false;
    }
    const float expectedX = expectedSegments[segmentIndex].x;
    const float expectedY = expectedSegments[segmentIndex].y;
    if (!preciseNear(x, expectedX) || !preciseNear(y, expectedY)) {
      mismatch = "segment " + std::to_string(segmentIndex) + " point expected " +
          std::to_string(expectedX) + "," + std::to_string(expectedY) + " got " +
          std::to_string(x) + "," + std::to_string(y);
      return false;
    }
  }
  if (expectedSegmentCount == 0) return !expectedClose;
  auto lastSegment = FPDFPath_GetPathSegment(object, expectedSegmentCount - 1);
  const bool actualClose = lastSegment != nullptr && FPDFPathSegment_GetClose(lastSegment);
  if (lastSegment == nullptr || actualClose != expectedClose) {
    mismatch = "final segment close marker differs";
    return false;
  }
  return true;
}

bool textPlacementMatchesExpected(FPDF_PAGEOBJECT object,
                         const FS_MATRIX& parent,
                         const TextPlacement& expected,
                         std::string& mismatch) {
  FS_MATRIX matrix{};
  float fontSize = 0;
  if (!FPDFPageObj_GetMatrix(object, &matrix) || !FPDFTextObj_GetFontSize(object, &fontSize)) {
    mismatch = "saved text transform or font size is unavailable";
    return false;
  }
  matrix = compose(parent, matrix);
  if (!preciseNear(matrix.a, expected.matrix.a) ||
      !preciseNear(matrix.b, expected.matrix.b) ||
      !preciseNear(matrix.c, expected.matrix.c) ||
      !preciseNear(matrix.d, expected.matrix.d) ||
      !preciseNear(matrix.e, expected.matrix.e) ||
      !preciseNear(matrix.f, expected.matrix.f)) {
    mismatch = "saved text transform differs from the explicit placement";
    return false;
  }
  if (!preciseNear(fontSize, expected.fontSize)) {
    mismatch = "saved text font size differs from the requested size";
    return false;
  }
  return true;
}

std::string writeImpl(
    const std::vector<std::uint8_t>& sourceBytes,
    const std::vector<std::int32_t>& pageIndices,
    const std::vector<double>& pageDimensions,
    const std::vector<std::int32_t>& pathPageIndices,
    const std::vector<std::int32_t>& pathCommandOffsets,
    const std::vector<std::int32_t>& pathCommandTypes,
    const std::vector<float>& pathCoordinates,
    const std::vector<std::int32_t>& textRunPageIndices,
    const std::vector<std::int32_t>& textRunLineIds,
    const std::vector<std::u16string>& textRunTexts,
    const std::vector<std::int32_t>& textRunSourceRanges,
    const std::vector<std::int32_t>& textRunBidiLevels,
    const std::vector<std::int32_t>& textRunVisualOrder,
    const std::vector<std::int32_t>& textRunBaseDirections,
    const std::vector<std::int32_t>& textRunAlignments,
    const std::vector<std::int32_t>& textRunFontIndices,
    const std::vector<float>& textRunGeometry,
    const std::vector<std::int32_t>& textRunColors,
    const std::vector<float>& textRunTransforms,
    const std::vector<std::optional<std::array<float, 4>>>& textRunClips,
    const std::vector<std::int32_t>& pageRotations,
    const std::vector<std::vector<std::uint8_t>>& fontResources,
    const std::vector<std::int32_t>& explicitFontSelections,
    const PdfiumTextShaper& shapeText,
    const std::vector<std::int32_t>& pathColors,
    bool maySubsetFonts,
    bool forceSubsetSaveFailureForTesting,
    std::int32_t inkColor,
    std::vector<std::uint8_t>& candidateBytes) {
  if ((!textRunClips.empty() && textRunClips.size() != textRunTexts.size()) || !shapeText || (!pathColors.empty() && pathColors.size() != pathPageIndices.size()) ||
      pageIndices.empty() || pageDimensions.size() != pageIndices.size() * 2 ||
      explicitFontSelections.size() != fontResources.size() ||
      pageRotations.size() != pageIndices.size() ||
      textRunTransforms.size() != textRunTexts.size() * 6 ||
      pathCommandOffsets.size() != pathPageIndices.size() + 1 ||
      pathCommandOffsets.empty() ||
      static_cast<std::size_t>(pathCommandOffsets.back()) != pathCommandTypes.size() ||
      pathCoordinates.size() != pathCommandTypes.size() * 6 ||
      textRunPageIndices.size() != textRunLineIds.size() ||
      textRunPageIndices.size() != textRunTexts.size() ||
      textRunSourceRanges.size() != textRunTexts.size() * 2 ||
      textRunBidiLevels.size() != textRunTexts.size() ||
      textRunVisualOrder.size() != textRunTexts.size() ||
      textRunBaseDirections.size() != textRunTexts.size() ||
      textRunAlignments.size() != textRunTexts.size() ||
      textRunFontIndices.size() != textRunTexts.size() ||
      textRunGeometry.size() != textRunTexts.size() * 5 ||
      textRunColors.size() != textRunTexts.size() ||
      textRunTexts.size() > static_cast<std::size_t>((std::numeric_limits<std::int32_t>::max)())) {
    return "PDFium export arrays have inconsistent sizes";
  }

  FPDF_DOCUMENT rawDocument = FPDF_LoadMemDocument(
      sourceBytes.data(), static_cast<int>(sourceBytes.size()), nullptr);
  if (rawDocument == nullptr) return "PDFium could not open the source document";
  ScopedDocument document(rawDocument);
  const int pageCount = FPDF_GetPageCount(rawDocument);
  if (pageCount <= 0 || static_cast<std::size_t>(pageCount) != pageIndices.size()) {
    return "Source page count does not match the export snapshot";
  }
  for (int pageIndex = 0; pageIndex < pageCount; ++pageIndex) {
    if (pageIndices[pageIndex] != pageIndex) return "Export page indices are not ordered";
    auto page = ScopedPage(FPDF_LoadPage(rawDocument, pageIndex));
    if (page.get() == nullptr || pageRotations[pageIndex] < 0 || pageRotations[pageIndex] > 3) {
      return "Export page rotation is invalid";
    }
    FPDFPage_SetRotation(page.get(), pageRotations[pageIndex]);
    if (page.get() == nullptr ||
        !dimensionsMatch(page.get(),
                         pageDimensions[pageIndex * 2], pageDimensions[pageIndex * 2 + 1])) {
      return "Source page dimensions do not match the export snapshot";
    }
  }

  std::vector<int> originalPaths(pageIndices.size());
  std::vector<int> originalTexts(pageIndices.size());
  for (int pageIndex = 0; pageIndex < pageCount; ++pageIndex) {
    auto page = ScopedPage(FPDF_LoadPage(rawDocument, pageIndex));
    if (page.get() == nullptr ||
        !objectCounts(page.get(), originalPaths[pageIndex], originalTexts[pageIndex])) {
      return "Unable to inspect source page objects";
    }
  }

  using LineKey = std::pair<int, int>;
  std::map<LineKey, std::vector<std::size_t>> runsByLine;
  for (std::size_t run = 0; run < textRunTexts.size(); ++run) {
    const auto pageIndex = textRunPageIndices[run];
    const auto sourceStart = textRunSourceRanges[run * 2];
    const auto sourceLength = textRunSourceRanges[run * 2 + 1];
    const auto geometryOffset = run * 5;
    const auto boundsLeft = textRunGeometry[geometryOffset];
    const auto boundsRight = textRunGeometry[geometryOffset + 1];
    const auto baseline = textRunGeometry[geometryOffset + 2];
    const auto fontSize = textRunGeometry[geometryOffset + 3];
    const auto estimatedAdvance = textRunGeometry[geometryOffset + 4];
    const auto fontIndex = textRunFontIndices[run];
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= pageIndices.size() ||
        sourceStart < 0 || sourceLength < 0 ||
        static_cast<std::size_t>(sourceStart + sourceLength) > textRunTexts[run].size() ||
        textRunBidiLevels[run] < 0 || textRunBidiLevels[run] > 125 ||
        textRunVisualOrder[run] < 0 ||
        (textRunBaseDirections[run] != 0 && textRunBaseDirections[run] != 1) ||
        textRunAlignments[run] < 0 || textRunAlignments[run] > 2 ||
        fontIndex < -1 ||
        (fontIndex >= 0 && static_cast<std::size_t>(fontIndex) >= fontResources.size()) ||
        !std::isfinite(boundsLeft) || !std::isfinite(boundsRight) ||
        boundsRight < boundsLeft || !std::isfinite(baseline) ||
        !std::isfinite(fontSize) || fontSize <= 0 ||
        !std::isfinite(estimatedAdvance) || estimatedAdvance < 0) {
      return "Resolved text run metadata is invalid";
    }
    runsByLine[{pageIndex, textRunLineIds[run]}].push_back(run);
  }

  std::vector<std::map<std::uint16_t, std::u16string>> unicodeByFont(fontResources.size());
  std::vector<std::map<std::uint16_t, std::uint16_t>> glyphByCid(fontResources.size());
  std::vector<std::uint16_t> maximumCid(fontResources.size(), 0);
  std::vector<std::vector<ShapedSegment>> shapedLines;
  shapedLines.reserve(runsByLine.size());
  for (const auto& [lineKey, lineRunIndices] : runsByLine) {
    const auto firstRun = lineRunIndices.front();
    const auto& lineText = textRunTexts[firstRun];
    const auto firstGeometry = firstRun * 5;
    const auto boundsLeft = textRunGeometry[firstGeometry];
    const auto boundsRight = textRunGeometry[firstGeometry + 1];
    const auto baseline = textRunGeometry[firstGeometry + 2];
    const auto fontSize = textRunGeometry[firstGeometry + 3];
    const auto lineColor = textRunColors[firstRun];
    const auto baseDirectionRtl = textRunBaseDirections[firstRun] != 0;
    const auto textAlignment = textRunAlignments[firstRun];

    std::vector<std::size_t> logicalRuns = lineRunIndices;
    std::sort(logicalRuns.begin(), logicalRuns.end(), [&](std::size_t left, std::size_t right) {
      return textRunSourceRanges[left * 2] < textRunSourceRanges[right * 2];
    });
    std::size_t expectedSourceStart = 0;
    for (const auto run : logicalRuns) {
      const auto geometry = run * 5;
      const auto sourceStart = static_cast<std::size_t>(textRunSourceRanges[run * 2]);
      const auto sourceLength = static_cast<std::size_t>(textRunSourceRanges[run * 2 + 1]);
      if ((!textRunClips.empty() && textRunClips[run] != textRunClips[firstRun]) ||
          textRunTexts[run] != lineText || textRunBaseDirections[run] != textRunBaseDirections[firstRun] ||
          textRunAlignments[run] != textAlignment ||
          textRunColors[run] != lineColor ||
          textRunGeometry[geometry] != boundsLeft ||
          textRunGeometry[geometry + 1] != boundsRight ||
          textRunGeometry[geometry + 2] != baseline ||
          textRunGeometry[geometry + 3] != fontSize ||
          sourceStart != expectedSourceStart) {
        return "Resolved text segments do not share one complete line layout";
      }
      expectedSourceStart += sourceLength;
    }
    if (expectedSourceStart != lineText.size()) {
      return "Resolved text segments do not cover the full logical line";
    }

    std::vector<std::size_t> visualRuns = lineRunIndices;
    std::sort(visualRuns.begin(), visualRuns.end(), [&](std::size_t left, std::size_t right) {
      return textRunVisualOrder[left] < textRunVisualOrder[right];
    });
    for (std::size_t order = 0; order < visualRuns.size(); ++order) {
      if (textRunVisualOrder[visualRuns[order]] != static_cast<std::int32_t>(order)) {
        return "Resolved text visual segment order is incomplete";
      }
    }

    std::vector<ShapedSegment> visualSegments;
    visualSegments.reserve(visualRuns.size());
    float totalAdvance = 0;
    for (const auto run : visualRuns) {
      const auto sourceStart = static_cast<std::size_t>(textRunSourceRanges[run * 2]);
      const auto sourceLength = static_cast<std::size_t>(textRunSourceRanges[run * 2 + 1]);
      const auto fontIndex = textRunFontIndices[run];
      const auto estimatedAdvance = textRunGeometry[run * 5 + 4];
      ShapedSegment segment{
          run, sourceStart, sourceLength, fontIndex, 0, baseline, fontSize,
          estimatedAdvance, textRunColors[run], {}};
      if (fontIndex >= 0 && sourceLength > 0) {
        const auto& bytes = fontResources[static_cast<std::size_t>(fontIndex)];
        auto shaped = shapeText(run, bytes,
          std::u16string_view(lineText).substr(sourceStart, sourceLength),
          (textRunBidiLevels[run] & 1) != 0, fontSize);
        if (shaped.error.empty() && !shaped.glyphs.empty()) {
          segment.advance = shaped.advance;
          segment.prepositioned = shaped.prepositioned;
          segment.glyphs.reserve(shaped.glyphs.size());
          for (auto& glyph : shaped.glyphs) {
            segment.glyphs.push_back({run,
              static_cast<std::uint32_t>(sourceStart + glyph.sourceOffset), glyph.order,
              fontIndex, glyph.glyphId, std::move(glyph.unicode), glyph.x,
              shaped.prepositioned ? glyph.y : baseline + glyph.y, fontSize, lineColor});
          }
          totalAdvance += segment.advance;
        } else {
          if (explicitFontSelections[static_cast<std::size_t>(fontIndex)] != 0)
            return shaped.error.empty() ? "Unable to shape text with the selected named font" : shaped.error;
          segment.fontIndex = -1;
          segment.glyphs.clear();
          segment.advance = estimatedAdvance;
        }
      }
      if (segment.fontIndex < 0) {
        segment.advance = estimatedAdvance;
        totalAdvance += segment.advance;
      }
      visualSegments.push_back(std::move(segment));
    }

    const float boundsWidth = (std::max)(0.0f, boundsRight - boundsLeft);
    const float horizontalScale = totalAdvance > boundsWidth && totalAdvance > 0
        ? boundsWidth / totalAdvance : 1.0f;
    const float laidOutWidth = totalAdvance * horizontalScale;
    const auto alignment = textRunAlignments[firstRun];
    float cursor = alignment == 1 ? boundsLeft + (boundsWidth - laidOutWidth) / 2.0f
        : alignment == 2 ? boundsRight - laidOutWidth : boundsLeft;
    for (auto& segment : visualSegments) {
      if (segment.prepositioned) continue;
      const float segmentWidth = segment.advance * horizontalScale;
      segment.originX = cursor;
      for (auto& glyph : segment.glyphs) {
        glyph.x = cursor + glyph.x * horizontalScale;
        glyph.horizontalScale = horizontalScale;
      }
      cursor += segmentWidth;
    }
    shapedLines.push_back(std::move(visualSegments));
  }

  std::vector<std::uint16_t> nextCid(fontResources.size(), 0);
  for (auto& line : shapedLines) {
    std::vector<ShapedGlyph*> logicalGlyphs;
    for (auto& segment : line) {
      for (auto& glyph : segment.glyphs) logicalGlyphs.push_back(&glyph);
    }
    std::sort(logicalGlyphs.begin(), logicalGlyphs.end(), [](const auto* left, const auto* right) {
      return left->sourceCluster != right->sourceCluster
          ? left->sourceCluster < right->sourceCluster
          : left->outputOrder < right->outputOrder;
    });
    for (auto* glyph : logicalGlyphs) {
      if (glyph->fontIndex < 0 ||
          static_cast<std::size_t>(glyph->fontIndex) >= fontResources.size() ||
          glyph->glyphId > 0xFFFF ||
          nextCid[static_cast<std::size_t>(glyph->fontIndex)] == 0xFFFF) {
        glyph->cid = 0;
        continue;
      }
      const auto font = static_cast<std::size_t>(glyph->fontIndex);
      glyph->cid = ++nextCid[font];
      unicodeByFont[font].emplace(glyph->cid, glyph->unicode);
      glyphByCid[font].emplace(glyph->cid, static_cast<std::uint16_t>(glyph->glyphId));
      maximumCid[font] = (std::max)(maximumCid[font], glyph->cid);
    }
  }

  std::vector<std::vector<std::uint8_t>> cidToGidMaps(fontResources.size());
  for (std::size_t font = 0; font < fontResources.size(); ++font) {
    if (maximumCid[font] == 0) continue;
    cidToGidMaps[font].resize((static_cast<std::size_t>(maximumCid[font]) + 1) * 2, 0);
    for (const auto& [cid, gid] : glyphByCid[font]) {
      const auto offset = static_cast<std::size_t>(cid) * 2;
      cidToGidMaps[font][offset] = static_cast<std::uint8_t>(gid >> 8);
      cidToGidMaps[font][offset + 1] = static_cast<std::uint8_t>(gid & 0xFF);
    }
  }

  std::vector<std::unique_ptr<ScopedFont>> loadedFonts(fontResources.size());
  std::vector<bool> fontAvailable(fontResources.size(), false);
  for (std::size_t font = 0; font < fontResources.size(); ++font) {
    if (maximumCid[font] == 0 || fontResources[font].empty() ||
        fontResources[font].size() > (std::numeric_limits<std::uint32_t>::max)()) {
      continue;
    }
    const auto cmap = buildToUnicodeCMap(unicodeByFont[font]);
    auto loaded = FPDFText_LoadCidType2Font(
        rawDocument, fontResources[font].data(),
        static_cast<std::uint32_t>(fontResources[font].size()), cmap.c_str(),
        cidToGidMaps[font].data(), static_cast<std::uint32_t>(cidToGidMaps[font].size()));
    if (loaded != nullptr) {
      loadedFonts[font] = std::make_unique<ScopedFont>(loaded);
      fontAvailable[font] = true;
    } else if (explicitFontSelections[font] != 0) {
      return "PDFium could not load the selected named font";
    }
  }

  bool needsFallbackText = false;
  for (const auto& line : shapedLines) {
    for (const auto& segment : line) {
      bool available = segment.fontIndex >= 0 && !segment.glyphs.empty() &&
          fontAvailable[static_cast<std::size_t>(segment.fontIndex)];
      if (available && std::any_of(segment.glyphs.begin(), segment.glyphs.end(),
                                   [](const auto& glyph) { return glyph.cid == 0; })) {
        available = false;
      }
      if (segment.fontIndex >= 0 && !available &&
          explicitFontSelections[static_cast<std::size_t>(segment.fontIndex)] != 0) {
        return "The supplied embedded font could not represent the shaped text";
      }
      needsFallbackText = needsFallbackText || !available;
    }
  }
  std::unique_ptr<ScopedFont> standardFont;
  if (needsFallbackText) {
    standardFont = std::make_unique<ScopedFont>(
        FPDFText_LoadStandardFont(rawDocument, "Helvetica"));
    if (standardFont->get() == nullptr) {
      return "PDFium could not load Helvetica for best-effort text export";
    }
  }


  std::vector<std::unique_ptr<ScopedPage>> pages(pageIndices.size());
  auto pageFor = [&](std::int32_t pageIndex) -> FPDF_PAGE {
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= pages.size()) return nullptr;
    auto& page = pages[static_cast<std::size_t>(pageIndex)];
    if (page == nullptr) {
      page = std::make_unique<ScopedPage>(FPDF_LoadPage(rawDocument, pageIndex));
    }
    return page->get();
  };

  std::vector<int> addedPaths(pageIndices.size(), 0);
  std::vector<std::vector<int>> expectedPathIndices(pageIndices.size());
  std::vector<TextPlacement> expectedTextPlacements;
  std::vector<std::vector<int>> expectedTextIndices(pageIndices.size());

  for (std::size_t pathIndex = 0; pathIndex < pathPageIndices.size(); ++pathIndex) {
    const auto pathColor = pathColors.empty() ? inkColor : pathColors[pathIndex];
    const unsigned int red = (static_cast<std::uint32_t>(pathColor) >> 16) & 0xFF;
    const unsigned int green = (static_cast<std::uint32_t>(pathColor) >> 8) & 0xFF;
    const unsigned int blue = static_cast<std::uint32_t>(pathColor) & 0xFF;
    const unsigned int alpha = (static_cast<std::uint32_t>(pathColor) >> 24) & 0xFF;
    const int pageIndex = pathPageIndices[pathIndex];
    const int begin = pathCommandOffsets[pathIndex];
    const int end = pathCommandOffsets[pathIndex + 1];
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= pages.size() ||
        begin < 0 || end <= begin || static_cast<std::size_t>(end) > pathCommandTypes.size()) {
      return "Path command offsets or page index are invalid";
    }
    auto page = pageFor(pageIndex);
    if (page == nullptr) return "PDFium could not load the page for an ink path";
    float visibleBoxLeft = 0.0f, visibleBoxBottom = 0.0f;
    float visibleBoxRight = 0.0f, visibleBoxTop = 0.0f;
    if (!readCoordinateBox(page, &visibleBoxLeft, &visibleBoxBottom,
                              &visibleBoxRight, &visibleBoxTop)) {
      return "PDFium could not read the page visible bounds for an ink path";
    }
    const auto pageCoordinateAt = [&](int commandIndex, int slot) -> float {
      const float value = pathCoordinates[static_cast<std::size_t>(commandIndex) * 6 + slot];
      if (slot == 1 || slot == 3 || slot == 5) {
        return visibleBoxTop - value;
      }
      return visibleBoxLeft + value;
    };
    if (pathCommandTypes[begin] != 0) return "Path does not begin with a move command";
    ScopedPageObject pathObject(
        FPDFPageObj_CreateNewPath(pageCoordinateAt(begin, 0), pageCoordinateAt(begin, 1)));
    if (pathObject.get() == nullptr) return "PDFium could not create an ink path";
    bool pathOk = true;
    for (int commandIndex = begin + 1; commandIndex < end && pathOk; ++commandIndex) {
      switch (pathCommandTypes[commandIndex]) {
        case 0:
          pathOk = FPDFPath_MoveTo(pathObject.get(), pageCoordinateAt(commandIndex, 0),
                                   pageCoordinateAt(commandIndex, 1));
          break;
        case 1:
          pathOk = FPDFPath_LineTo(pathObject.get(), pageCoordinateAt(commandIndex, 0),
                                   pageCoordinateAt(commandIndex, 1));
          break;
        case 2:
          pathOk = FPDFPath_BezierTo(
              pathObject.get(), pageCoordinateAt(commandIndex, 2),
              pageCoordinateAt(commandIndex, 3), pageCoordinateAt(commandIndex, 4),
              pageCoordinateAt(commandIndex, 5), pageCoordinateAt(commandIndex, 0),
              pageCoordinateAt(commandIndex, 1));
          break;
        case 3:
          pathOk = FPDFPath_Close(pathObject.get());
          break;
        default:
          pathOk = false;
          break;
      }
    }
    if (!pathOk || !FPDFPath_SetDrawMode(pathObject.get(), FPDF_FILLMODE_WINDING, false) ||
        !FPDFPageObj_SetFillColor(pathObject.get(), red, green, blue, alpha)) {
      return "PDFium could not set ink path geometry or color";
    }
    if (!FPDFPage_InsertObject(page, pathObject.get())) {
      return "PDFium could not insert an ink path";
    }
    pathObject.release();
    ++addedPaths[static_cast<std::size_t>(pageIndex)];
    expectedPathIndices[static_cast<std::size_t>(pageIndex)].push_back(
        static_cast<int>(pathIndex));
  }

  auto recordTextPlacement = [&](const TextPlacement& placement) {
    const int placementIndex = static_cast<int>(expectedTextPlacements.size());
    expectedTextPlacements.push_back(placement);
    expectedTextIndices[static_cast<std::size_t>(placement.pageIndex)].push_back(placementIndex);
  };
  auto setTextColor = [](FPDF_PAGEOBJECT object, std::int32_t color) {
    return FPDFPageObj_SetFillColor(
        object,
        (static_cast<std::uint32_t>(color) >> 16) & 0xFF,
        (static_cast<std::uint32_t>(color) >> 8) & 0xFF,
        static_cast<std::uint32_t>(color) & 0xFF,
        (static_cast<std::uint32_t>(color) >> 24) & 0xFF);
  };
  auto textMatrix = [&](std::size_t runIndex, float x, float baselineTop,
                             double visibleBoxLeft, double visibleBoxTop,
                             float horizontalScale = 1.0f) {
    const auto* t = textRunTransforms.data() + runIndex * 6;
    return FS_MATRIX{t[0] * horizontalScale, -t[1] * horizontalScale, -t[2], t[3],
      static_cast<float>(visibleBoxLeft + t[0] * x + t[2] * baselineTop + t[4]),
      static_cast<float>(visibleBoxTop - (t[1] * x + t[3] * baselineTop + t[5]))};
  };



  std::size_t lineIndex = 0;
  for (const auto& [lineKey, lineRunIndices] : runsByLine) {
    const int pageIndex = lineKey.first;
    auto page = pageFor(pageIndex);
    if (page == nullptr) return "Text run page index is invalid";
    float visibleBoxLeft = 0.0f, visibleBoxBottom = 0.0f;
    float visibleBoxRight = 0.0f, visibleBoxTop = 0.0f;
    if (!readCoordinateBox(page, &visibleBoxLeft, &visibleBoxBottom,
                              &visibleBoxRight, &visibleBoxTop)) {
      return "PDFium could not read the page visible bounds for text";
    }
    auto& segments = shapedLines[lineIndex++];
    std::sort(segments.begin(), segments.end(), [&](const auto& left, const auto& right) {
      return textRunVisualOrder[left.runIndex] < textRunVisualOrder[right.runIndex];
    });
    const auto& lineText = textRunTexts[lineRunIndices.front()];
    const bool baseDirectionRtl = textRunBaseDirections[lineRunIndices.front()] != 0;
    std::vector<std::unique_ptr<ScopedPageObject>> lineObjects;
    std::vector<TextPlacement> placements;

    for (const auto& segment : segments) {
      const bool fontReady = segment.fontIndex >= 0 && !segment.glyphs.empty() &&
          fontAvailable[static_cast<std::size_t>(segment.fontIndex)] &&
          std::none_of(segment.glyphs.begin(), segment.glyphs.end(),
                       [](const auto& glyph) { return glyph.cid == 0; });
      bool canDrawGlyphs = fontReady;
      std::vector<std::unique_ptr<ScopedPageObject>> segmentObjects;
      std::vector<TextPlacement> segmentPlacements;
      if (canDrawGlyphs) {
        segmentObjects.reserve(segment.glyphs.size());
        segmentPlacements.reserve(segment.glyphs.size());
        for (const auto& glyph : segment.glyphs) {
          if (!std::isfinite(glyph.x) || !std::isfinite(glyph.baselineFromTop) ||
              !std::isfinite(glyph.horizontalScale) || glyph.horizontalScale < 0) {
            canDrawGlyphs = false;
            break;
          }
          auto object = std::make_unique<ScopedPageObject>(FPDFPageObj_CreateTextObj(
              rawDocument, loadedFonts[static_cast<std::size_t>(glyph.fontIndex)]->get(),
              glyph.fontSize));
          const std::uint32_t cid = glyph.cid;
          const FS_MATRIX matrix = textMatrix(glyph.runIndex, glyph.x, glyph.baselineFromTop,
                                               visibleBoxLeft, visibleBoxTop, glyph.horizontalScale);
          if (object->get() == nullptr ||
              !FPDFText_SetCharcodes(object->get(), &cid, 1) ||
              !FPDFTextObj_SetTextRenderMode(object->get(), FPDF_TEXTRENDERMODE_FILL) ||
              !setTextColor(object->get(), glyph.color) ||
              !FPDFPageObj_TransformF(object->get(), &matrix)) {
            canDrawGlyphs = false;
            break;
          }
          segmentPlacements.push_back(
              {pageIndex, glyph.fontSize, matrix});
          segmentObjects.push_back(std::move(object));
        }
      }
      if (canDrawGlyphs) {
        for (auto& object : segmentObjects) lineObjects.push_back(std::move(object));
        placements.insert(placements.end(), segmentPlacements.begin(),
                          segmentPlacements.end());
        continue;
      }

      if (segment.fontIndex >= 0 &&
          explicitFontSelections[static_cast<std::size_t>(segment.fontIndex)] != 0) {
        return "PDFium could not draw text with the selected named font";
      }

      const auto logicalText = lineText.substr(segment.sourceStart, segment.sourceLength);
      ScopedPageObject textObject(FPDFPageObj_CreateTextObj(
          rawDocument, standardFont->get(), segment.fontSize));
      if (textObject.get() == nullptr) {
        return "PDFium could not create best-effort text content";
      }
      std::vector<FPDF_WCHAR> utf16;
      utf16.reserve(logicalText.size() + 1);
      for (char16_t character : logicalText) {
        utf16.push_back(static_cast<FPDF_WCHAR>(character));
      }
      utf16.push_back(0);
      const FS_MATRIX matrix = textMatrix(segment.runIndex, segment.originX, segment.baselineFromTop,
                                           visibleBoxLeft, visibleBoxTop);
      if (!FPDFText_SetText(textObject.get(), utf16.data()) ||
          !FPDFTextObj_SetTextRenderMode(textObject.get(), FPDF_TEXTRENDERMODE_FILL) ||
          !setTextColor(textObject.get(), segment.color) ||
          !FPDFPageObj_TransformF(textObject.get(), &matrix)) {
        return "PDFium could not set best-effort text contents or placement";
      }
      placements.push_back(
          {pageIndex, segment.fontSize, matrix});
      lineObjects.push_back(std::make_unique<ScopedPageObject>(textObject.release()));
    }

    if (lineObjects.empty()) continue;
    FPDF_PAGEOBJECTMARK mark = FPDFPageObj_AddMark(lineObjects.front()->get(), "Span");
    if (mark == nullptr) return "PDFium could not mark the logical text line";
    std::vector<std::uint8_t> actualText{0xFE, 0xFF};
    actualText.reserve(2 + lineText.size() * 2);
    for (const char16_t character : lineText) {
      const auto value = static_cast<std::uint16_t>(character);
      actualText.push_back(static_cast<std::uint8_t>(value >> 8));
      actualText.push_back(static_cast<std::uint8_t>(value & 0xFF));
    }
    if (!FPDFPageObjMark_SetBlobParam(
            rawDocument, lineObjects.front()->get(), mark, "ActualText",
            actualText.data(), static_cast<unsigned long>(actualText.size())) ||
        !FPDFPageObjMark_SetStringParam(
            rawDocument, lineObjects.front()->get(), mark, "InkSignBaseDirection",
            baseDirectionRtl ? "RTL" : "LTR")) {
      return "PDFium could not attach the logical text mapping";
    }
    for (std::size_t objectIndex = 1; objectIndex < lineObjects.size(); ++objectIndex) {
      if (!FPDFPageObj_AddExistingMark(lineObjects[objectIndex]->get(), mark)) {
        return "PDFium could not extend the logical text mapping";
      }
    }

    const auto& clip = textRunClips.empty()
        ? std::optional<std::array<float, 4>>{} : textRunClips[lineRunIndices.front()];
    std::unique_ptr<ScopedPage> clippedPage;
    FPDF_PAGE destination = page;
    if (clip) {
      const auto& bounds = *clip;
      if (!std::all_of(bounds.begin(), bounds.end(), [](float value) { return std::isfinite(value); }) ||
          bounds[2] <= bounds[0] || bounds[3] <= bounds[1])
        return "Text clip rectangle is invalid";
      clippedPage = std::make_unique<ScopedPage>(FPDFPage_New(rawDocument, pageCount,
          visibleBoxRight - visibleBoxLeft, visibleBoxTop - visibleBoxBottom));
      if (clippedPage->get() == nullptr) return "Could not create isolated text page";
      destination = clippedPage->get();
    }
    for (std::size_t objectIndex = 0; objectIndex < lineObjects.size(); ++objectIndex) {
      auto& object = lineObjects[objectIndex];
      if (clip) FPDFPageObj_Transform(object->get(), 1, 0, 0, 1, -visibleBoxLeft, -visibleBoxBottom);
      if (!FPDFPage_InsertObject(destination, object->get())) {
        return "PDFium could not insert a shaped text glyph";
      }
      object->release();
      const auto& placement = placements[objectIndex];
      recordTextPlacement(placement);
    }
    if (clip) {
      if (!FPDFPage_GenerateContent(destination)) return "Could not generate isolated text content";
      const auto run = lineRunIndices.front();
      const auto transform = run * 6;
      // Captured layout orientation is a quarter turn; its rectangle remains axis-aligned.
      const float a = textRunTransforms[transform], b = textRunTransforms[transform + 1];
      const float c = textRunTransforms[transform + 2], d = textRunTransforms[transform + 3];
      if (!((std::abs(b) < 0.001f && std::abs(c) < 0.001f) ||
            (std::abs(a) < 0.001f && std::abs(d) < 0.001f)))
        return "Text clip requires a rectilinear layout transform";
      float left = std::numeric_limits<float>::max(), bottom = left;
      float right = std::numeric_limits<float>::lowest(), top = right;
      for (float x : {(*clip)[0], (*clip)[2]}) {
        for (float y : {(*clip)[1], (*clip)[3]}) {
          const float px = a * x + c * y + textRunTransforms[transform + 4];
          const float py = visibleBoxTop - visibleBoxBottom -
              (b * x + d * y + textRunTransforms[transform + 5]);
          left = std::min(left, px); right = std::max(right, px);
          bottom = std::min(bottom, py); top = std::max(top, py);
        }
      }
      const auto clipPath = FPDF_CreateClipPath(left, bottom, right, top);
      if (clipPath == nullptr) return "Could not create text clip";
      FPDFPage_InsertClipPath(destination, clipPath);
      FPDF_DestroyClipPath(clipPath);
      const auto xobject = FPDF_NewXObjectFromPage(rawDocument, rawDocument, pageCount);
      if (xobject == nullptr) return "Could not create clipped text form";
      ScopedPageObject form(FPDF_NewFormObjectFromXObject(xobject));
      FPDF_CloseXObject(xobject);
      if (form.get() == nullptr) return "Could not instantiate clipped text form";
      FPDFPageObj_Transform(form.get(), 1, 0, 0, 1, visibleBoxLeft, visibleBoxBottom);
      if (!FPDFPage_InsertObject(page, form.get())) return "Could not insert clipped text form";
      form.release();
      clippedPage.reset();
      FPDFPage_Delete(rawDocument, pageCount);
    }
  }

  for (auto& page : pages) {
    if (page != nullptr && !FPDFPage_GenerateContent(page->get())) {
      return "PDFium could not generate page content";
    }
  }
  pages.clear();

  const bool hasMultiUnitUnicodeMapping = std::any_of(
      unicodeByFont.begin(), unicodeByFont.end(), [](const auto& mappings) {
        return std::any_of(mappings.begin(), mappings.end(), [](const auto& mapping) {
          return mapping.second.size() > 1;
        });
      });
  const bool shouldSubsetFonts = maySubsetFonts && !hasMultiUnitUnicodeMapping;
  VectorFileWriter writer;
  const FPDF_DWORD saveFlags = FPDF_NO_INCREMENTAL |
      (shouldSubsetFonts ? FPDF_SUBSET_NEW_FONTS : 0);
  if (shouldSubsetFonts) {
    const bool savedWithSubset = !forceSubsetSaveFailureForTesting &&
        FPDF_SaveAsCopy(rawDocument, &writer.api, saveFlags) && !writer.bytes.empty();
    if (!savedWithSubset) {
      writer.bytes.clear();
      if (!FPDF_SaveAsCopy(rawDocument, &writer.api, FPDF_NO_INCREMENTAL) ||
          writer.bytes.empty()) {
        return "PDFium could not save the exported candidate with or without font subsetting";
      }
    }
  } else if (!FPDF_SaveAsCopy(rawDocument, &writer.api, FPDF_NO_INCREMENTAL) ||
             writer.bytes.empty()) {
    return "PDFium could not save the exported candidate";
  }

  FPDF_DOCUMENT rawCandidate = FPDF_LoadMemDocument(
      writer.bytes.data(), static_cast<int>(writer.bytes.size()), nullptr);
  if (rawCandidate == nullptr) return "PDFium could not reopen the exported candidate";
  ScopedDocument candidate(rawCandidate);
  if (FPDF_GetPageCount(rawCandidate) != pageCount) {
    return "Exported page count does not match the source";
  }
  std::vector<int> addedTexts(pageIndices.size(), 0);
  for (std::size_t pageIndex = 0; pageIndex < addedPaths.size(); ++pageIndex) {
    addedTexts[pageIndex] = static_cast<int>(expectedTextIndices[pageIndex].size());
  }
  std::vector<std::vector<int>> expectedTextPlacementIndices = expectedTextIndices;
  for (int pageIndex = 0; pageIndex < pageCount; ++pageIndex) {
    auto page = ScopedPage(FPDF_LoadPage(rawCandidate, pageIndex));
    int pathCount = 0;
    int textCount = 0;
    if (page.get() == nullptr ||
        !dimensionsMatch(page.get(),
                         pageDimensions[pageIndex * 2], pageDimensions[pageIndex * 2 + 1]) ||
        FPDFPage_GetRotation(page.get()) != pageRotations[pageIndex] ||
        !objectCounts(page.get(), pathCount, textCount) ||
        pathCount != originalPaths[pageIndex] + addedPaths[pageIndex] ||
        textCount != originalTexts[pageIndex] + addedTexts[pageIndex]) {
      return "Saved candidate page metadata or vector object counts do not match";
    }
    float visibleBoxLeft = 0.0f, visibleBoxBottom = 0.0f;
    float visibleBoxRight = 0.0f, visibleBoxTop = 0.0f;
    if (!readCoordinateBox(page.get(), &visibleBoxLeft, &visibleBoxBottom,
                              &visibleBoxRight, &visibleBoxTop)) {
      return "Saved candidate visible bounds are unavailable";
    }

    int seenPaths = 0;
    int seenTexts = 0;
    int addedPathIndex = 0;
    std::vector<LeafObject> addedTextObjects;
    std::vector<LeafObject> leaves;
    if (!pageLeaves(page.get(), leaves)) return "Saved candidate contains an invalid form";
    for (const auto& leaf : leaves) {
      const auto object = leaf.object;
      const auto type = FPDFPageObj_GetType(object);
      if (type == FPDF_PAGEOBJ_PATH) {
        if (seenPaths++ >= originalPaths[pageIndex]) {
          const int expectedIndex = expectedPathIndices[pageIndex][addedPathIndex++];
          const int begin = pathCommandOffsets[expectedIndex];
          const int end = pathCommandOffsets[expectedIndex + 1];
          std::string mismatch;
          if (!pathMatchesExpected(object, begin, end, pathCommandTypes, pathCoordinates,
                                   visibleBoxLeft, visibleBoxTop, mismatch)) {
            return "Saved candidate path geometry does not match the export snapshot: " + mismatch;
          }
        }
      } else if (type == FPDF_PAGEOBJ_TEXT) {
        if (seenTexts++ >= originalTexts[pageIndex]) {
          addedTextObjects.push_back(leaf);
        }
      }
    }
    if (addedPathIndex != static_cast<int>(expectedPathIndices[pageIndex].size()) ||
        addedTextObjects.size() != expectedTextPlacementIndices[pageIndex].size()) {
      return "Saved candidate omitted an exported vector object";
    }
    std::vector<bool> matchedText(expectedTextPlacementIndices[pageIndex].size(), false);
    for (auto object : addedTextObjects) {
      bool matched = false;
      std::string lastMismatch = "no matching explicit text placement";
      for (std::size_t localIndex = 0;
           localIndex < expectedTextPlacementIndices[pageIndex].size(); ++localIndex) {
        if (matchedText[localIndex]) continue;
        const int expectedIndex = expectedTextPlacementIndices[pageIndex][localIndex];
        if (expectedIndex < 0 ||
            static_cast<std::size_t>(expectedIndex) >= expectedTextPlacements.size()) {
          return "Saved candidate text placement metadata is invalid";
        }
        const auto& expected = expectedTextPlacements[static_cast<std::size_t>(expectedIndex)];
        if (textPlacementMatchesExpected(
                object.object, object.parent, expected, lastMismatch)) {
          matchedText[localIndex] = true;
          matched = true;
          break;
        }
      }
      if (!matched) {
        return "Saved candidate text object has no matching explicit placement: " + lastMismatch;
      }
    }
  }
  candidateBytes = std::move(writer.bytes);
  return {};
}
}  // namespace

PdfiumError PdfiumContentWriter::write(const std::vector<std::uint8_t>& sourceBytes,
                                     const PdfiumContentInput& input,
                                     const PdfiumTextShaper& shapeText,
                                     std::vector<std::uint8_t>& outputBytes) {
  PdfiumError failure;
  auto library = PdfiumLibrary::acquire(failure);
  if (!library) return failure;
  auto& state = pdfiumLibraryState();
  std::lock_guard lock(state.apiMutex);
  auto message = writeImpl(sourceBytes,
      input.pageIndices,
      input.pageDimensions,
      input.pathPageIndices,
      input.pathCommandOffsets,
      input.pathCommandTypes,
      input.pathCoordinates,
      input.textRunPageIndices,
      input.textRunLineIds,
      input.textRunTexts,
      input.textRunSourceRanges,
      input.textRunBidiLevels,
      input.textRunVisualOrder,
      input.textRunBaseDirections,
      input.textRunAlignments,
      input.textRunFontIndices,
      input.textRunGeometry,
      input.textRunColors,
      input.textRunTransforms,
      input.textRunClips,
      input.pageRotations,
      input.fontResources,
      input.explicitFontSelections, shapeText, input.pathColors,
      input.maySubsetFonts, input.forceSubsetSaveFailureForTesting, input.inkColor, outputBytes);
  return {message.empty() ? PdfiumErrorCode::None : PdfiumErrorCode::ValidationFailed, std::move(message)};
}
}  // namespace margelo::nitro::inksignpdf::pdfium
