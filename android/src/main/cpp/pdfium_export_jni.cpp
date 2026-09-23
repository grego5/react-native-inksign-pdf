#include <jni.h>

#include <fpdf_edit.h>
#include <fpdf_save.h>
#include <fpdfview.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include "pdfium-adapter/PdfiumLibraryInternal.hpp"

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
                         const std::vector<jfloat>& expectedGeometry,
                         std::size_t geometryOffset,
                         double pageHeight,
                         std::string& mismatch) {
  FS_MATRIX matrix{};
  float fontSize = 0;
  if (!FPDFPageObj_GetMatrix(object, &matrix) || !FPDFTextObj_GetFontSize(object, &fontSize)) {
    mismatch = "saved text transform or font size is unavailable";
    return false;
  }
  if (!preciseNear(matrix.e, expectedGeometry[geometryOffset]) ||
      !preciseNear(matrix.f, pageHeight - expectedGeometry[geometryOffset + 1])) {
    mismatch = "saved text transform differs from the explicit placement";
    return false;
  }
  if (!preciseNear(fontSize, expectedGeometry[geometryOffset + 2])) {
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
    const std::vector<jint>& textPageIndices,
    const std::vector<std::u16string>& texts,
    const std::vector<jint>& textFontKinds,
    const std::vector<jfloat>& textGeometry,
    const std::vector<jint>& textColors,
    jint inkColor,
    const std::vector<std::uint8_t>& hebrewFontBytes,
    const std::vector<std::uint8_t>& arabicFontBytes,
    std::vector<std::uint8_t>& candidateBytes) {
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

  std::vector<FPDF_PAGE> pages(pageIndices.size(), nullptr);
  auto pageFor = [&](jint pageIndex) -> FPDF_PAGE {
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= pages.size()) return nullptr;
    auto& page = pages[static_cast<std::size_t>(pageIndex)];
    if (page == nullptr) page = FPDF_LoadPage(rawDocument, pageIndex);
    return page;
  };

  ScopedFont standardFont(FPDFText_LoadStandardFont(rawDocument, "Helvetica"));
  bool needsHebrew = false;
  bool needsArabic = false;
  for (auto kind : textFontKinds) {
    if (kind == 1) needsHebrew = true;
    else if (kind == 2) needsArabic = true;
    else if (kind != 0) return "Text font kind is invalid";
  }
  if (!textFontKinds.empty() && standardFont.get() == nullptr) {
    return "PDFium could not load Helvetica for export";
  }
  ScopedFont hebrewFont(needsHebrew && !hebrewFontBytes.empty()
      ? FPDFText_LoadFont(rawDocument, hebrewFontBytes.data(),
                          static_cast<uint32_t>(hebrewFontBytes.size()),
                          FPDF_FONT_TRUETYPE, true)
      : nullptr);
  ScopedFont arabicFont(needsArabic && !arabicFontBytes.empty()
      ? FPDFText_LoadFont(rawDocument, arabicFontBytes.data(),
                          static_cast<uint32_t>(arabicFontBytes.size()),
                          FPDF_FONT_TRUETYPE, true)
      : nullptr);
  if (needsHebrew && hebrewFont.get() == nullptr) return "PDFium could not load the Hebrew font";
  if (needsArabic && arabicFont.get() == nullptr) return "PDFium could not load the Arabic font";

  const unsigned int red = (static_cast<std::uint32_t>(inkColor) >> 16) & 0xFF;
  const unsigned int green = (static_cast<std::uint32_t>(inkColor) >> 8) & 0xFF;
  const unsigned int blue = static_cast<std::uint32_t>(inkColor) & 0xFF;
  const unsigned int alpha = (static_cast<std::uint32_t>(inkColor) >> 24) & 0xFF;

  for (std::size_t pathIndex = 0; pathIndex < pathPageIndices.size(); ++pathIndex) {
    const int begin = pathCommandOffsets[pathIndex];
    const int end = pathCommandOffsets[pathIndex + 1];
    if (begin < 0 || end <= begin || static_cast<std::size_t>(end) > pathCommandTypes.size()) {
      return "Path command offsets are invalid";
    }
    const auto commandAt = [&](int commandIndex, int slot) -> float {
      return pathCoordinates[static_cast<std::size_t>(commandIndex) * 6 + slot];
    };
    if (pathCommandTypes[begin] != 0) return "Path does not begin with a move command";
    auto pathObject = FPDFPageObj_CreateNewPath(
        commandAt(begin, 0), commandAt(begin, 1));
    if (pathObject == nullptr) return "PDFium could not create an ink path";
    bool pathOk = true;
    for (int commandIndex = begin + 1; commandIndex < end && pathOk; ++commandIndex) {
      switch (pathCommandTypes[commandIndex]) {
        case 0:
          pathOk = FPDFPath_MoveTo(pathObject, commandAt(commandIndex, 0),
                                   commandAt(commandIndex, 1));
          break;
        case 1:
          pathOk = FPDFPath_LineTo(pathObject, commandAt(commandIndex, 0),
                                   commandAt(commandIndex, 1));
          break;
        case 2:
          pathOk = FPDFPath_BezierTo(
              pathObject, commandAt(commandIndex, 2), commandAt(commandIndex, 3),
              commandAt(commandIndex, 4), commandAt(commandIndex, 5),
              commandAt(commandIndex, 0), commandAt(commandIndex, 1));
          break;
        case 3:
          pathOk = FPDFPath_Close(pathObject);
          break;
        default:
          pathOk = false;
          break;
      }
    }
    if (!pathOk || !FPDFPath_SetDrawMode(pathObject, FPDF_FILLMODE_WINDING, false) ||
        !FPDFPageObj_SetFillColor(pathObject, red, green, blue, alpha)) {
      FPDFPageObj_Destroy(pathObject);
      return "PDFium could not set ink path geometry or color";
    }
    auto page = pageFor(pathPageIndices[pathIndex]);
    if (page == nullptr) {
      FPDFPageObj_Destroy(pathObject);
      return "Ink path page index is invalid";
    }
    if (!FPDFPage_InsertObject(page, pathObject)) {
      return "PDFium could not insert an ink path";
    }
  }

  for (std::size_t textIndex = 0; textIndex < texts.size(); ++textIndex) {
    const auto pageIndex = textPageIndices[textIndex];
    auto page = pageFor(pageIndex);
    if (page == nullptr) return "Text page index is invalid";
    const int fontKind = textFontKinds[textIndex];
    FPDF_FONT font = fontKind == 1 ? hebrewFont.get()
        : fontKind == 2 ? arabicFont.get() : standardFont.get();
    auto textObject = FPDFPageObj_CreateTextObj(
        rawDocument, font, textGeometry[textIndex * 3 + 2]);
    if (textObject == nullptr) return "PDFium could not create a text object";
    std::vector<FPDF_WCHAR> utf16;
    utf16.reserve(texts[textIndex].size() + 1);
    for (char16_t character : texts[textIndex]) {
      utf16.push_back(static_cast<FPDF_WCHAR>(character));
    }
    utf16.push_back(0);
    const bool textOk = FPDFText_SetText(textObject, utf16.data()) &&
        FPDFTextObj_SetTextRenderMode(textObject, FPDF_TEXTRENDERMODE_FILL) &&
        FPDFPageObj_SetFillColor(
            textObject,
            (static_cast<std::uint32_t>(textColors[textIndex]) >> 16) & 0xFF,
            (static_cast<std::uint32_t>(textColors[textIndex]) >> 8) & 0xFF,
            static_cast<std::uint32_t>(textColors[textIndex]) & 0xFF,
            (static_cast<std::uint32_t>(textColors[textIndex]) >> 24) & 0xFF);
    const float x = textGeometry[textIndex * 3];
    const float baselineTop = textGeometry[textIndex * 3 + 1];
    const double pageHeight = FPDF_GetPageHeightF(page);
    if (!textOk || !std::isfinite(x) || !std::isfinite(baselineTop)) {
      FPDFPageObj_Destroy(textObject);
      return "PDFium could not set text contents, color, or position";
    }
    FPDFPageObj_Transform(textObject, 1, 0, 0, 1, x, pageHeight - baselineTop);
    if (!FPDFPage_InsertObject(page, textObject)) {
      return "PDFium could not insert a text object";
    }
  }

  for (auto page : pages) {
    if (page != nullptr && !FPDFPage_GenerateContent(page)) {
      for (auto loaded : pages) if (loaded != nullptr) FPDF_ClosePage(loaded);
      std::fill(pages.begin(), pages.end(), nullptr);
      return "PDFium could not generate page content";
    }
  }
  for (auto page : pages) if (page != nullptr) FPDF_ClosePage(page);
  std::fill(pages.begin(), pages.end(), nullptr);

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
  std::vector<int> addedPaths(pageIndices.size(), 0);
  std::vector<int> addedTexts(pageIndices.size(), 0);
  std::vector<std::vector<int>> expectedPathIndices(pageIndices.size());
  std::vector<std::vector<int>> expectedTextIndices(pageIndices.size());
  for (auto pageIndex : pathPageIndices) {
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= addedPaths.size()) {
      return "Exported path page index is invalid";
    }
    ++addedPaths[static_cast<std::size_t>(pageIndex)];
  }
  for (std::size_t index = 0; index < pathPageIndices.size(); ++index) {
    expectedPathIndices[static_cast<std::size_t>(pathPageIndices[index])].push_back(
        static_cast<int>(index));
  }
  for (std::size_t index = 0; index < textPageIndices.size(); ++index) {
    const auto pageIndex = textPageIndices[index];
    if (pageIndex < 0 || static_cast<std::size_t>(pageIndex) >= addedTexts.size()) {
      return "Exported text page index is invalid";
    }
    ++addedTexts[static_cast<std::size_t>(pageIndex)];
    expectedTextIndices[static_cast<std::size_t>(pageIndex)].push_back(
        static_cast<int>(index));
  }
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
        addedTextObjects.size() != expectedTextIndices[pageIndex].size()) {
      return "Saved candidate omitted an exported vector object";
    }
    std::vector<bool> matchedText(expectedTextIndices[pageIndex].size(), false);
    for (auto object : addedTextObjects) {
      bool matched = false;
      std::string lastMismatch = "no matching explicit text placement";
      for (std::size_t localIndex = 0;
           localIndex < expectedTextIndices[pageIndex].size(); ++localIndex) {
        if (matchedText[localIndex]) continue;
        const int expectedIndex = expectedTextIndices[pageIndex][localIndex];
        const auto geometryOffset = static_cast<std::size_t>(expectedIndex) * 3;
        if (textPlacementMatchesExpected(
                object, textGeometry, geometryOffset,
                FPDF_GetPageHeightF(page.get()), lastMismatch)) {
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
    jintArray textPageIndicesValue,
    jobjectArray textsValue,
    jintArray textFontKindsValue,
    jfloatArray textGeometryValue,
    jintArray textColorsValue,
    jint inkColor,
    jbyteArray hebrewFontValue,
    jbyteArray arabicFontValue) {
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
  std::vector<jint> textPageIndices;
  std::vector<jint> textFontKinds;
  std::vector<jfloat> textGeometry;
  std::vector<jint> textColors;
  std::vector<std::uint8_t> hebrewFontBytes;
  std::vector<std::uint8_t> arabicFontBytes;
  if (!copyArray(env, pageIndicesValue, pageIndices) ||
      !copyArray(env, pageDimensionsValue, pageDimensions) ||
      !copyArray(env, pathPageIndicesValue, pathPageIndices) ||
      !copyArray(env, pathCommandOffsetsValue, pathCommandOffsets) ||
      !copyArray(env, pathCommandTypesValue, pathCommandTypes) ||
      !copyArray(env, pathCoordinatesValue, pathCoordinates) ||
      !copyArray(env, textPageIndicesValue, textPageIndices) ||
      !copyArray(env, textFontKindsValue, textFontKinds) ||
      !copyArray(env, textGeometryValue, textGeometry) ||
      !copyArray(env, textColorsValue, textColors) ||
      !copyBytes(env, hebrewFontValue, hebrewFontBytes) ||
      !copyBytes(env, arabicFontValue, arabicFontBytes)) {
    if (!env->ExceptionCheck()) {
      throwJava(env, "java/lang/IllegalArgumentException", "PDF export data is invalid");
    }
    return;
  }
  if (textsValue == nullptr) {
    throwJava(env, "java/lang/IllegalArgumentException", "PDF export text array is missing");
    return;
  }
  const auto textCount = env->GetArrayLength(textsValue);
  std::vector<std::u16string> texts;
  texts.reserve(static_cast<std::size_t>(textCount));
  for (jsize index = 0; index < textCount; ++index) {
    auto text = static_cast<jstring>(env->GetObjectArrayElement(textsValue, index));
    if (text == nullptr) {
      throwJava(env, "java/lang/IllegalArgumentException", "PDF export text entry is null");
      return;
    }
    const jsize length = env->GetStringLength(text);
    const jchar* characters = env->GetStringChars(text, nullptr);
    if (characters == nullptr) return;
    std::u16string copied;
    copied.reserve(static_cast<std::size_t>(length));
    for (jsize character = 0; character < length; ++character) {
      copied.push_back(static_cast<char16_t>(characters[character]));
    }
    env->ReleaseStringChars(text, characters);
    env->DeleteLocalRef(text);
    texts.push_back(std::move(copied));
  }
  if (pageIndices.empty() || pageDimensions.size() != pageIndices.size() * 2 ||
      pathCommandOffsets.size() != pathPageIndices.size() + 1 ||
      pathCommandOffsets.empty() || pathCommandOffsets.back() != pathCommandTypes.size() ||
      pathCoordinates.size() != pathCommandTypes.size() * 6 ||
      textPageIndices.size() != texts.size() || textFontKinds.size() != texts.size() ||
      textGeometry.size() != texts.size() * 3 || textColors.size() != texts.size()) {
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
                      pathCoordinates, textPageIndices, texts, textFontKinds,
                      textGeometry, textColors, inkColor, hebrewFontBytes,
                      arabicFontBytes, candidateBytes);
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
