#include <jni.h>

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

#include "pdfium_android_text_shaper.hpp"
#include "pdfium-adapter/PdfiumContentWriter.hpp"

namespace {

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
    jintArray pageRotationsValue,
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
    jintArray textRunAlignmentsValue,
    jintArray textRunFontIndicesValue,
    jfloatArray textRunGeometryValue,
    jintArray textRunColorsValue,
    jfloatArray textRunTransformsValue,
    jobjectArray fontResourcesValue,
    jintArray explicitFontSelectionsValue,
    jboolean maySubsetFontsValue,
    jboolean forceSubsetSaveFailureForTestingValue,
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
  std::vector<jint> pageRotations;
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
  std::vector<jint> textRunAlignments;
  std::vector<jint> textRunFontIndices;
  std::vector<jfloat> textRunGeometry;
  std::vector<jint> textRunColors;
  std::vector<jfloat> textRunTransforms;
  std::vector<std::vector<std::uint8_t>> fontResources;
  std::vector<jint> explicitFontSelections;

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
      !copyArray(env, pageRotationsValue, pageRotations) ||
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
      !copyArray(env, textRunAlignmentsValue, textRunAlignments) ||
      !copyArray(env, textRunFontIndicesValue, textRunFontIndices) ||
      !copyArray(env, textRunGeometryValue, textRunGeometry) ||
      !copyArray(env, textRunColorsValue, textRunColors) ||
      !copyArray(env, textRunTransformsValue, textRunTransforms) ||
      !copyFontResources(fontResourcesValue) ||
      !copyArray(env, explicitFontSelectionsValue, explicitFontSelections)) {
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
      textRunAlignments.size() != textRunTexts.size() ||
      textRunFontIndices.size() != textRunTexts.size() ||
      textRunGeometry.size() != textRunTexts.size() * 5 ||
      textRunColors.size() != textRunTexts.size()) {
    throwJava(env, "java/lang/IllegalArgumentException", "PDF export arrays have inconsistent sizes");
    return;
  }

  margelo::nitro::inksignpdf::pdfium::PdfiumContentInput input;
  input.pageIndices = std::move(pageIndices);
  input.pageDimensions = std::move(pageDimensions);
  input.pathPageIndices = std::move(pathPageIndices);
  input.pathCommandOffsets = std::move(pathCommandOffsets);
  input.pathCommandTypes = std::move(pathCommandTypes);
  input.pathCoordinates = std::move(pathCoordinates);
  input.textRunPageIndices = std::move(textRunPageIndices);
  input.textRunLineIds = std::move(textRunLineIds);
  input.textRunTexts = std::move(textRunTexts);
  input.textRunSourceRanges = std::move(textRunSourceRanges);
  input.textRunBidiLevels = std::move(textRunBidiLevels);
  input.textRunVisualOrder = std::move(textRunVisualOrder);
  input.textRunBaseDirections = std::move(textRunBaseDirections);
  input.textRunAlignments = std::move(textRunAlignments);
  input.textRunFontIndices = std::move(textRunFontIndices);
  input.textRunGeometry = std::move(textRunGeometry);
  input.textRunColors = std::move(textRunColors);
  input.textRunTransforms = std::move(textRunTransforms);
  input.pageRotations = std::move(pageRotations);
  input.fontResources = std::move(fontResources);
  input.explicitFontSelections = std::move(explicitFontSelections);
  input.maySubsetFonts = maySubsetFontsValue == JNI_TRUE;
  input.forceSubsetSaveFailureForTesting = forceSubsetSaveFailureForTestingValue == JNI_TRUE;
  input.inkColor = inkColor;
  std::vector<std::uint8_t> candidateBytes;
  auto result = margelo::nitro::inksignpdf::pdfium::PdfiumContentWriter::write(
    sourceBytes, input, shapeAndroidPdfText, candidateBytes);
  const auto& error = result.message;
  if (!result) {
    throwJava(env, "java/lang/IllegalStateException", error.empty() ? "PDFium export failed" : error);
    return;
  }
  std::ofstream output(destinationPath, std::ios::binary | std::ios::trunc);
  if (!output || !output.write(reinterpret_cast<const char*>(candidateBytes.data()),
                               static_cast<std::streamsize>(candidateBytes.size()))) {
    throwJava(env, "java/lang/IllegalStateException", "Unable to write the PDFium export candidate");
  }
}
