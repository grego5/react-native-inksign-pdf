#include <jni.h>

#include <fpdf_edit.h>
#include <fpdf_save.h>
#include <fpdfview.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include "pdfium-adapter/PdfiumLibraryInternal.hpp"
#include "pdfium_harfbuzz_api.h"

namespace {

using margelo::nitro::inksignpdf::pdfium::PdfiumLibrary;
using margelo::nitro::inksignpdf::pdfium::PdfiumError;
using margelo::nitro::inksignpdf::pdfium::pdfiumLibraryState;

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

struct HbBlobDeleter final {
  void operator()(hb_blob_t* value) const {
    if (value != nullptr) hb_blob_destroy(value);
  }
};
struct HbFaceDeleter final {
  void operator()(hb_face_t* value) const {
    if (value != nullptr) hb_face_destroy(value);
  }
};
struct HbFontDeleter final {
  void operator()(hb_font_t* value) const {
    if (value != nullptr) hb_font_destroy(value);
  }
};
struct HbBufferDeleter final {
  void operator()(hb_buffer_t* value) const {
    if (value != nullptr) hb_buffer_destroy(value);
  }
};

using ScopedHbBlob = std::unique_ptr<hb_blob_t, HbBlobDeleter>;
using ScopedHbFace = std::unique_ptr<hb_face_t, HbFaceDeleter>;
using ScopedHbFont = std::unique_ptr<hb_font_t, HbFontDeleter>;
using ScopedHbBuffer = std::unique_ptr<hb_buffer_t, HbBufferDeleter>;

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
  jint color;
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
  jint color;
  std::vector<ShapedGlyph> glyphs;
};

struct TextPlacement final {
  int pageIndex;
  float x;
  float baselineFromTop;
  float fontSize;
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

bool readPath(JNIEnv* env, jstring value, std::string& path) {
  if (value == nullptr) return false;
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return false;
  path.assign(chars);
  env->ReleaseStringUTFChars(value, chars);
  return !path.empty();
}

bool readFile(const std::string& path, std::vector<std::uint8_t>& bytes) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) return false;
  const auto end = input.tellg();
  if (end <= 0 || static_cast<std::uint64_t>(end) >
                      static_cast<std::uint64_t>((std::numeric_limits<int>::max)())) {
    return false;
  }
  bytes.resize(static_cast<std::size_t>(end));
  input.seekg(0, std::ios::beg);
  return static_cast<bool>(input.read(
      reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())));
}

template <typename T, typename JArray>
bool copyArray(JNIEnv* env, JArray array, std::vector<T>& result) {
  if (array == nullptr) return false;
  const auto size = env->GetArrayLength(array);
  result.resize(static_cast<std::size_t>(size));
  if (size == 0) return true;
  if constexpr (std::is_same_v<T, jint>) {
    env->GetIntArrayRegion(array, 0, size, result.data());
  } else if constexpr (std::is_same_v<T, jfloat>) {
    env->GetFloatArrayRegion(array, 0, size, result.data());
  } else if constexpr (std::is_same_v<T, jdouble>) {
    env->GetDoubleArrayRegion(array, 0, size, result.data());
  }
  return !env->ExceptionCheck();
}

bool copyBytes(JNIEnv* env, jbyteArray array, std::vector<std::uint8_t>& result) {
  if (array == nullptr) return false;
  const auto size = env->GetArrayLength(array);
  result.resize(static_cast<std::size_t>(size));
  if (size > 0) {
    env->GetByteArrayRegion(array, 0, size, reinterpret_cast<jbyte*>(result.data()));
  }
  return !env->ExceptionCheck();
}

bool objectCounts(FPDF_PAGE page, int& paths, int& texts) {
  paths = 0;
  texts = 0;
  const int objectCount = FPDFPage_CountObjects(page);
  if (objectCount < 0) return false;
  for (int index = 0; index < objectCount; ++index) {
    const auto object = FPDFPage_GetObject(page, index);
    if (object == nullptr) return false;
    const auto type = FPDFPageObj_GetType(object);
    if (type == FPDF_PAGEOBJ_PATH) ++paths;
    if (type == FPDF_PAGEOBJ_TEXT) ++texts;
  }
  return true;
}

bool near(double actual, double expected) {
  return std::isfinite(actual) && std::isfinite(expected) &&
         std::abs(actual - expected) <= 0.05;
}

bool preciseNear(double actual, double expected) {
  return std::isfinite(actual) && std::isfinite(expected) &&
         std::abs(actual - expected) <= 0.001;
}

float pathCoordinate(const std::vector<jfloat>& coordinates,
                     int commandIndex,
                     int slot) {
  return coordinates[static_cast<std::size_t>(commandIndex) * 6 + slot];
}

bool pathMatchesExpected(FPDF_PAGEOBJECT object,
                         int begin,
                         int end,
                         const std::vector<jint>& commandTypes,
                         const std::vector<jfloat>& coordinates,
                         std::string& mismatch) {
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
      startX = currentX = pathCoordinate(coordinates, commandIndex, 0);
      startY = currentY = pathCoordinate(coordinates, commandIndex, 1);
      hasCurrentPoint = true;
      expectedSegments.push_back({FPDF_SEGMENT_MOVETO, currentX, currentY});
    } else if (commandType == 1) {
      currentX = pathCoordinate(coordinates, commandIndex, 0);
      currentY = pathCoordinate(coordinates, commandIndex, 1);
      expectedSegments.push_back({FPDF_SEGMENT_LINETO, currentX, currentY});
    } else if (commandType == 2) {
      expectedSegments.push_back({FPDF_SEGMENT_BEZIERTO,
          pathCoordinate(coordinates, commandIndex, 2),
          pathCoordinate(coordinates, commandIndex, 3)});
      expectedSegments.push_back({FPDF_SEGMENT_BEZIERTO,
          pathCoordinate(coordinates, commandIndex, 4),
          pathCoordinate(coordinates, commandIndex, 5)});
      currentX = pathCoordinate(coordinates, commandIndex, 0);
      currentY = pathCoordinate(coordinates, commandIndex, 1);
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
                         const TextPlacement& expected,
                         double pageHeight,
                         std::string& mismatch) {
  FS_MATRIX matrix{};
  float fontSize = 0;
  if (!FPDFPageObj_GetMatrix(object, &matrix) || !FPDFTextObj_GetFontSize(object, &fontSize)) {
    mismatch = "saved text transform or font size is unavailable";
    return false;
  }
  if (!preciseNear(matrix.e, expected.x) ||
      !preciseNear(matrix.f, pageHeight - expected.baselineFromTop)) {
    mismatch = "saved text transform differs from the explicit placement";
    return false;
  }
  if (!preciseNear(fontSize, expected.fontSize)) {
    mismatch = "saved text font size differs from the requested size";
    return false;
  }
  return true;
}

std::string exportPdf(
    const std::vector<std::uint8_t>& sourceBytes,
    const std::vector<jint>& pageIndices,
    const std::vector<jdouble>& pageDimensions,
    const std::vector<jint>& pathPageIndices,
    const std::vector<jint>& pathCommandOffsets,
    const std::vector<jint>& pathCommandTypes,
    const std::vector<jfloat>& pathCoordinates,
    const std::vector<jint>& textRunPageIndices,
    const std::vector<jint>& textRunLineIds,
    const std::vector<std::u16string>& textRunTexts,
    const std::vector<jint>& textRunSourceRanges,
    const std::vector<jint>& textRunBidiLevels,
    const std::vector<jint>& textRunVisualOrder,
    const std::vector<jint>& textRunBaseDirections,
    const std::vector<jint>& textRunFontIndices,
    const std::vector<jfloat>& textRunGeometry,
    const std::vector<jint>& textRunColors,
    const std::vector<std::vector<std::uint8_t>>& fontResources,
    jint inkColor,
    std::vector<std::uint8_t>& candidateBytes) {
  if (pageIndices.empty() || pageDimensions.size() != pageIndices.size() * 2 ||
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
      textRunFontIndices.size() != textRunTexts.size() ||
      textRunGeometry.size() != textRunTexts.size() * 5 ||
      textRunColors.size() != textRunTexts.size() ||
      textRunTexts.size() > static_cast<std::size_t>((std::numeric_limits<jint>::max)())) {
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
    if (page.get() == nullptr ||
        !near(FPDF_GetPageWidthF(page.get()), pageDimensions[pageIndex * 2]) ||
        !near(FPDF_GetPageHeightF(page.get()), pageDimensions[pageIndex * 2 + 1])) {
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

    std::vector<std::size_t> logicalRuns = lineRunIndices;
    std::sort(logicalRuns.begin(), logicalRuns.end(), [&](std::size_t left, std::size_t right) {
      return textRunSourceRanges[left * 2] < textRunSourceRanges[right * 2];
    });
    std::size_t expectedSourceStart = 0;
    for (const auto run : logicalRuns) {
      const auto geometry = run * 5;
      const auto sourceStart = static_cast<std::size_t>(textRunSourceRanges[run * 2]);
      const auto sourceLength = static_cast<std::size_t>(textRunSourceRanges[run * 2 + 1]);
      if (textRunTexts[run] != lineText || textRunBaseDirections[run] != textRunBaseDirections[firstRun] ||
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
      if (textRunVisualOrder[visualRuns[order]] != static_cast<jint>(order)) {
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
        if (!bytes.empty() &&
            bytes.size() <= (std::numeric_limits<unsigned int>::max)() &&
            sourceLength <= static_cast<std::size_t>((std::numeric_limits<int>::max)())) {
          ScopedHbBlob blob(hb_blob_create(
              reinterpret_cast<const char*>(bytes.data()),
              static_cast<unsigned int>(bytes.size()), HB_MEMORY_MODE_READONLY,
              nullptr, nullptr));
          ScopedHbFace face(blob == nullptr ? nullptr : hb_face_create(blob.get(), 0));
          ScopedHbFont font(face == nullptr ? nullptr : hb_font_create(face.get()));
          ScopedHbBuffer buffer(hb_buffer_create());
          const auto textBegin = lineText.data() + sourceStart;
          const auto fontScale = static_cast<int>((std::lround)(fontSize * 64.0f));
          bool shapedOk = blob != nullptr && face != nullptr && font != nullptr &&
              buffer != nullptr && fontScale > 0;
          if (shapedOk) {
            hb_ot_font_set_funcs(font.get());
            hb_font_set_scale(font.get(), fontScale, fontScale);
            hb_buffer_set_cluster_level(buffer.get(),
                                        HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
            hb_buffer_set_direction(
                buffer.get(), (textRunBidiLevels[run] & 1) != 0
                    ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
            hb_buffer_add_utf16(
                buffer.get(), reinterpret_cast<const std::uint16_t*>(textBegin),
                static_cast<int>(sourceLength), 0, static_cast<int>(sourceLength));
            hb_buffer_guess_segment_properties(buffer.get());
            hb_shape(font.get(), buffer.get(), nullptr, 0);
            unsigned int infoCount = 0;
            unsigned int positionCount = 0;
            auto* infos = hb_buffer_get_glyph_infos(buffer.get(), &infoCount);
            auto* positions = hb_buffer_get_glyph_positions(buffer.get(), &positionCount);
            shapedOk = infoCount == positionCount &&
                (infoCount == 0 || (infos != nullptr && positions != nullptr));
            if (shapedOk && infoCount > 0) {
              std::vector<std::uint32_t> clusterStarts;
              clusterStarts.reserve(infoCount);
              double penX = 0;
              double penY = 0;
              struct RawGlyph final {
                std::uint32_t cluster;
                std::size_t order;
                std::uint32_t glyphId;
                double x;
                double y;
              };
              std::vector<RawGlyph> rawGlyphs;
              rawGlyphs.reserve(infoCount);
              for (unsigned int glyph = 0; glyph < infoCount; ++glyph) {
                const auto cluster = (std::min)(infos[glyph].cluster,
                    static_cast<std::uint32_t>(sourceLength - 1));
                clusterStarts.push_back(cluster);
                rawGlyphs.push_back({
                    cluster, glyph, infos[glyph].codepoint,
                    (penX + positions[glyph].x_offset) / 64.0,
                    -(penY + positions[glyph].y_offset) / 64.0});
                penX += positions[glyph].x_advance;
                penY += positions[glyph].y_advance;
              }
              std::sort(clusterStarts.begin(), clusterStarts.end());
              clusterStarts.erase(std::unique(clusterStarts.begin(), clusterStarts.end()),
                                  clusterStarts.end());
              const double rawAdvance = penX / 64.0;
              segment.advance = static_cast<float>(std::abs(rawAdvance));
              const double runMin = (std::min)(0.0, rawAdvance);
              std::map<std::uint32_t, bool> clusterMapped;
              segment.glyphs.reserve(rawGlyphs.size());
              for (const auto& glyph : rawGlyphs) {
                const auto nextCluster = std::upper_bound(
                    clusterStarts.begin(), clusterStarts.end(), glyph.cluster);
                const auto clusterEnd = nextCluster == clusterStarts.end()
                    ? sourceLength : static_cast<std::size_t>(*nextCluster);
                const auto logicalStart = sourceStart + glyph.cluster;
                const auto logicalLength = clusterEnd > glyph.cluster
                    ? clusterEnd - glyph.cluster : 1;
                std::u16string unicode;
                if (!clusterMapped[glyph.cluster]) {
                  unicode = lineText.substr(logicalStart, logicalLength);
                  clusterMapped[glyph.cluster] = true;
                }
                segment.glyphs.push_back({
                    run, static_cast<std::uint32_t>(logicalStart), glyph.order,
                    fontIndex, glyph.glyphId, std::move(unicode),
                    static_cast<float>(glyph.x - runMin),
                    static_cast<float>(baseline + glyph.y), fontSize, lineColor});
              }
              totalAdvance += segment.advance;
            } else {
              shapedOk = false;
            }
          }
          if (!shapedOk) {
            segment.fontIndex = -1;
            segment.glyphs.clear();
            segment.advance = estimatedAdvance;
          }
        } else {
          segment.fontIndex = -1;
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
    float cursor = baseDirectionRtl ? boundsRight - laidOutWidth : boundsLeft;
    for (auto& segment : visualSegments) {
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
  auto pageFor = [&](jint pageIndex) -> FPDF_PAGE {
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= pages.size()) return nullptr;
    auto& page = pages[static_cast<std::size_t>(pageIndex)];
    if (page == nullptr) {
      page = std::make_unique<ScopedPage>(FPDF_LoadPage(rawDocument, pageIndex));
    }
    return page->get();
  };

  const unsigned int red = (static_cast<std::uint32_t>(inkColor) >> 16) & 0xFF;
  const unsigned int green = (static_cast<std::uint32_t>(inkColor) >> 8) & 0xFF;
  const unsigned int blue = static_cast<std::uint32_t>(inkColor) & 0xFF;
  const unsigned int alpha = (static_cast<std::uint32_t>(inkColor) >> 24) & 0xFF;
  std::vector<int> addedPaths(pageIndices.size(), 0);
  std::vector<std::vector<int>> expectedPathIndices(pageIndices.size());
  std::vector<TextPlacement> expectedTextPlacements;
  std::vector<std::vector<int>> expectedTextIndices(pageIndices.size());

  for (std::size_t pathIndex = 0; pathIndex < pathPageIndices.size(); ++pathIndex) {
    const int pageIndex = pathPageIndices[pathIndex];
    const int begin = pathCommandOffsets[pathIndex];
    const int end = pathCommandOffsets[pathIndex + 1];
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= pages.size() ||
        begin < 0 || end <= begin || static_cast<std::size_t>(end) > pathCommandTypes.size()) {
      return "Path command offsets or page index are invalid";
    }
    const auto commandAt = [&](int commandIndex, int slot) -> float {
      return pathCoordinates[static_cast<std::size_t>(commandIndex) * 6 + slot];
    };
    if (pathCommandTypes[begin] != 0) return "Path does not begin with a move command";
    ScopedPageObject pathObject(
        FPDFPageObj_CreateNewPath(commandAt(begin, 0), commandAt(begin, 1)));
    if (pathObject.get() == nullptr) return "PDFium could not create an ink path";
    bool pathOk = true;
    for (int commandIndex = begin + 1; commandIndex < end && pathOk; ++commandIndex) {
      switch (pathCommandTypes[commandIndex]) {
        case 0:
          pathOk = FPDFPath_MoveTo(pathObject.get(), commandAt(commandIndex, 0),
                                   commandAt(commandIndex, 1));
          break;
        case 1:
          pathOk = FPDFPath_LineTo(pathObject.get(), commandAt(commandIndex, 0),
                                   commandAt(commandIndex, 1));
          break;
        case 2:
          pathOk = FPDFPath_BezierTo(
              pathObject.get(), commandAt(commandIndex, 2), commandAt(commandIndex, 3),
              commandAt(commandIndex, 4), commandAt(commandIndex, 5),
              commandAt(commandIndex, 0), commandAt(commandIndex, 1));
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
    auto page = pageFor(pageIndex);
    if (page == nullptr || !FPDFPage_InsertObject(page, pathObject.get())) {
      return "PDFium could not insert an ink path";
    }
    pathObject.release();
    ++addedPaths[static_cast<std::size_t>(pageIndex)];
    expectedPathIndices[static_cast<std::size_t>(pageIndex)].push_back(
        static_cast<int>(pathIndex));
  }

  auto recordTextPlacement = [&](int pageIndex, float x, float baselineTop, float fontSize) {
    const int placementIndex = static_cast<int>(expectedTextPlacements.size());
    expectedTextPlacements.push_back({pageIndex, x, baselineTop, fontSize});
    expectedTextIndices[static_cast<std::size_t>(pageIndex)].push_back(placementIndex);
  };
  auto setTextColor = [](FPDF_PAGEOBJECT object, jint color) {
    return FPDFPageObj_SetFillColor(
        object,
        (static_cast<std::uint32_t>(color) >> 16) & 0xFF,
        (static_cast<std::uint32_t>(color) >> 8) & 0xFF,
        static_cast<std::uint32_t>(color) & 0xFF,
        (static_cast<std::uint32_t>(color) >> 24) & 0xFF);
  };
  auto setTextTransform = [](FPDF_PAGEOBJECT object, float x, float baselineTop,
                             double pageHeight, float horizontalScale = 1.0f) {
    const FS_MATRIX matrix{horizontalScale, 0.0f, 0.0f, 1.0f, x,
                           static_cast<float>(pageHeight - baselineTop)};
    return FPDFPageObj_TransformF(object, &matrix);
  };



  std::size_t lineIndex = 0;
  for (const auto& [lineKey, lineRunIndices] : runsByLine) {
    const int pageIndex = lineKey.first;
    auto page = pageFor(pageIndex);
    if (page == nullptr) return "Text run page index is invalid";
    const double pageHeight = FPDF_GetPageHeightF(page);
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
          if (object->get() == nullptr ||
              !FPDFText_SetCharcodes(object->get(), &cid, 1) ||
              !FPDFTextObj_SetTextRenderMode(object->get(), FPDF_TEXTRENDERMODE_FILL) ||
              !setTextColor(object->get(), glyph.color) ||
              !setTextTransform(object->get(), glyph.x, glyph.baselineFromTop,
                                pageHeight, glyph.horizontalScale)) {
            canDrawGlyphs = false;
            break;
          }
          segmentPlacements.push_back(
              {pageIndex, glyph.x, glyph.baselineFromTop, glyph.fontSize});
          segmentObjects.push_back(std::move(object));
        }
      }
      if (canDrawGlyphs) {
        for (auto& object : segmentObjects) lineObjects.push_back(std::move(object));
        placements.insert(placements.end(), segmentPlacements.begin(),
                          segmentPlacements.end());
        continue;
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
      if (!FPDFText_SetText(textObject.get(), utf16.data()) ||
          !FPDFTextObj_SetTextRenderMode(textObject.get(), FPDF_TEXTRENDERMODE_FILL) ||
          !setTextColor(textObject.get(), segment.color) ||
          !setTextTransform(textObject.get(), segment.originX, segment.baselineFromTop,
                            pageHeight)) {
        return "PDFium could not set best-effort text contents or placement";
      }
      placements.push_back(
          {pageIndex, segment.originX, segment.baselineFromTop, segment.fontSize});
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

    for (std::size_t objectIndex = 0; objectIndex < lineObjects.size(); ++objectIndex) {
      auto& object = lineObjects[objectIndex];
      if (!FPDFPage_InsertObject(page, object->get())) {
        return "PDFium could not insert a shaped text glyph";
      }
      object->release();
      const auto& placement = placements[objectIndex];
      recordTextPlacement(pageIndex, placement.x, placement.baselineFromTop,
                          placement.fontSize);
    }
  }

  for (auto& page : pages) {
    if (page != nullptr && !FPDFPage_GenerateContent(page->get())) {
      return "PDFium could not generate page content";
    }
  }
  pages.clear();

  VectorFileWriter writer;
  if (!FPDF_SaveAsCopy(rawDocument, &writer.api, FPDF_NO_INCREMENTAL) ||
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
        !near(FPDF_GetPageWidthF(page.get()), pageDimensions[pageIndex * 2]) ||
        !near(FPDF_GetPageHeightF(page.get()), pageDimensions[pageIndex * 2 + 1]) ||
        !objectCounts(page.get(), pathCount, textCount) ||
        pathCount != originalPaths[pageIndex] + addedPaths[pageIndex] ||
        textCount != originalTexts[pageIndex] + addedTexts[pageIndex]) {
      return "Saved candidate page metadata or vector object counts do not match";
    }

    int seenPaths = 0;
    int seenTexts = 0;
    int addedPathIndex = 0;
    std::vector<FPDF_PAGEOBJECT> addedTextObjects;
    const int objectCount = FPDFPage_CountObjects(page.get());
    for (int objectIndex = 0; objectIndex < objectCount; ++objectIndex) {
      auto object = FPDFPage_GetObject(page.get(), objectIndex);
      if (object == nullptr) return "Saved candidate contains an invalid page object";
      const auto type = FPDFPageObj_GetType(object);
      if (type == FPDF_PAGEOBJ_PATH) {
        if (seenPaths++ >= originalPaths[pageIndex]) {
          const int expectedIndex = expectedPathIndices[pageIndex][addedPathIndex++];
          const int begin = pathCommandOffsets[expectedIndex];
          const int end = pathCommandOffsets[expectedIndex + 1];
          std::string mismatch;
          if (!pathMatchesExpected(object, begin, end, pathCommandTypes, pathCoordinates, mismatch)) {
            return "Saved candidate path geometry does not match the export snapshot: " + mismatch;
          }
        }
      } else if (type == FPDF_PAGEOBJ_TEXT) {
        if (seenTexts++ >= originalTexts[pageIndex]) {
          addedTextObjects.push_back(object);
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
                object, expected, FPDF_GetPageHeightF(page.get()), lastMismatch)) {
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
void throwJava(JNIEnv* env, const char* className, const std::string& message) {
  jclass exceptionClass = env->FindClass(className);
  if (exceptionClass != nullptr) env->ThrowNew(exceptionClass, message.c_str());
}

}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumNativePdfExporter_nativeExport(
    JNIEnv* env,
    jobject,
    jstring sourcePathValue,
    jstring destinationPathValue,
    jintArray pageIndicesValue,
    jdoubleArray pageDimensionsValue,
    jintArray pathPageIndicesValue,
    jintArray pathCommandOffsetsValue,
    jintArray pathCommandTypesValue,
    jfloatArray pathCoordinatesValue,
    jintArray textRunPageIndicesValue,
    jintArray textRunLineIdsValue,
    jobjectArray textRunTextsValue,
    jintArray textRunSourceRangesValue,
    jintArray textRunBidiLevelsValue,
    jintArray textRunVisualOrderValue,
    jintArray textRunBaseDirectionsValue,
    jintArray textRunFontIndicesValue,
    jfloatArray textRunGeometryValue,
    jintArray textRunColorsValue,
    jobjectArray fontResourcesValue,
    jint inkColor) {
  std::string sourcePath;
  std::string destinationPath;
  if (!readPath(env, sourcePathValue, sourcePath) ||
      !readPath(env, destinationPathValue, destinationPath)) {
    throwJava(env, "java/lang/IllegalArgumentException", "PDF export paths are invalid");
    return;
  }
  std::vector<std::uint8_t> sourceBytes;
  if (!readFile(sourcePath, sourceBytes)) {
    throwJava(env, "java/lang/IllegalArgumentException", "Unable to read PDF export source");
    return;
  }

  std::vector<jint> pageIndices;
  std::vector<jdouble> pageDimensions;
  std::vector<jint> pathPageIndices;
  std::vector<jint> pathCommandOffsets;
  std::vector<jint> pathCommandTypes;
  std::vector<jfloat> pathCoordinates;
  std::vector<jint> textRunPageIndices;
  std::vector<jint> textRunLineIds;
  std::vector<std::u16string> textRunTexts;
  std::vector<jint> textRunSourceRanges;
  std::vector<jint> textRunBidiLevels;
  std::vector<jint> textRunVisualOrder;
  std::vector<jint> textRunBaseDirections;
  std::vector<jint> textRunFontIndices;
  std::vector<jfloat> textRunGeometry;
  std::vector<jint> textRunColors;
  std::vector<std::vector<std::uint8_t>> fontResources;

  auto copyStrings = [&](jobjectArray values, std::vector<std::u16string>& result) {
    if (values == nullptr) return false;
    const auto count = env->GetArrayLength(values);
    result.reserve(static_cast<std::size_t>(count));
    for (jsize index = 0; index < count; ++index) {
      auto text = static_cast<jstring>(env->GetObjectArrayElement(values, index));
      if (text == nullptr) return false;
      const jsize length = env->GetStringLength(text);
      const jchar* characters = env->GetStringChars(text, nullptr);
      if (characters == nullptr) {
        env->DeleteLocalRef(text);
        return false;
      }
      std::u16string copied;
      copied.reserve(static_cast<std::size_t>(length));
      for (jsize character = 0; character < length; ++character) {
        copied.push_back(static_cast<char16_t>(characters[character]));
      }
      env->ReleaseStringChars(text, characters);
      env->DeleteLocalRef(text);
      result.push_back(std::move(copied));
    }
    return !env->ExceptionCheck();
  };
  auto copyFontResources = [&](jobjectArray values) {
    if (values == nullptr) return false;
    const auto count = env->GetArrayLength(values);
    fontResources.reserve(static_cast<std::size_t>(count));
    for (jsize index = 0; index < count; ++index) {
      auto bytes = static_cast<jbyteArray>(env->GetObjectArrayElement(values, index));
      std::vector<std::uint8_t> copied;
      const bool copiedOk = copyBytes(env, bytes, copied);
      if (bytes != nullptr) env->DeleteLocalRef(bytes);
      if (!copiedOk) return false;
      fontResources.push_back(std::move(copied));
    }
    return !env->ExceptionCheck();
  };

  if (!copyArray(env, pageIndicesValue, pageIndices) ||
      !copyArray(env, pageDimensionsValue, pageDimensions) ||
      !copyArray(env, pathPageIndicesValue, pathPageIndices) ||
      !copyArray(env, pathCommandOffsetsValue, pathCommandOffsets) ||
      !copyArray(env, pathCommandTypesValue, pathCommandTypes) ||
      !copyArray(env, pathCoordinatesValue, pathCoordinates) ||
      !copyArray(env, textRunPageIndicesValue, textRunPageIndices) ||
      !copyArray(env, textRunLineIdsValue, textRunLineIds) ||
      !copyStrings(textRunTextsValue, textRunTexts) ||
      !copyArray(env, textRunSourceRangesValue, textRunSourceRanges) ||
      !copyArray(env, textRunBidiLevelsValue, textRunBidiLevels) ||
      !copyArray(env, textRunVisualOrderValue, textRunVisualOrder) ||
      !copyArray(env, textRunBaseDirectionsValue, textRunBaseDirections) ||
      !copyArray(env, textRunFontIndicesValue, textRunFontIndices) ||
      !copyArray(env, textRunGeometryValue, textRunGeometry) ||
      !copyArray(env, textRunColorsValue, textRunColors) ||
      !copyFontResources(fontResourcesValue)) {
    if (!env->ExceptionCheck()) {
      throwJava(env, "java/lang/IllegalArgumentException", "PDF export data is invalid");
    }
    return;
  }
  if (pageIndices.empty() || pageDimensions.size() != pageIndices.size() * 2 ||
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
      textRunFontIndices.size() != textRunTexts.size() ||
      textRunGeometry.size() != textRunTexts.size() * 5 ||
      textRunColors.size() != textRunTexts.size()) {
    throwJava(env, "java/lang/IllegalArgumentException", "PDF export arrays have inconsistent sizes");
    return;
  }

  PdfiumError libraryError;
  auto library = PdfiumLibrary::acquire(libraryError);
  if (!library) {
    throwJava(env, "java/lang/IllegalStateException",
              libraryError.message.empty() ? "Unable to initialize PDFium" : libraryError.message);
    return;
  }
  std::vector<std::uint8_t> candidateBytes;
  std::string error;
  {
    auto& state = pdfiumLibraryState();
    std::lock_guard apiLock(state.apiMutex);
    error = exportPdf(sourceBytes, pageIndices, pageDimensions,
                      pathPageIndices, pathCommandOffsets, pathCommandTypes,
                      pathCoordinates, textRunPageIndices, textRunLineIds,
                      textRunTexts, textRunSourceRanges, textRunBidiLevels,
                      textRunVisualOrder, textRunBaseDirections, textRunFontIndices,
                      textRunGeometry, textRunColors, fontResources, inkColor,
                      candidateBytes);
  }
  if (!error.empty()) {
    throwJava(env, "java/lang/IllegalStateException", error);
    return;
  }
  std::ofstream output(destinationPath, std::ios::binary | std::ios::trunc);
  if (!output || !output.write(reinterpret_cast<const char*>(candidateBytes.data()),
                               static_cast<std::streamsize>(candidateBytes.size()))) {
    throwJava(env, "java/lang/IllegalStateException", "Unable to write the PDFium export candidate");
  }
}
