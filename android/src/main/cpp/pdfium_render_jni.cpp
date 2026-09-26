#include <jni.h>

#include <android/bitmap.h>

#include <cassert>
#include <cstdint>
#include <cmath>
#include <fstream>
#include <limits>
#include <span>
#include <string>
#include <vector>

#include "pdfium-adapter/PdfiumDocumentSession.hpp"
#include "pdfium-adapter/PdfiumPageAssembler.hpp"

namespace {

using margelo::nitro::inksignpdf::pdfium::PdfiumDocumentSession;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageMetadata;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageRenderRequest;
using margelo::nitro::inksignpdf::pdfium::PdfiumAppendInput;
using margelo::nitro::inksignpdf::pdfium::PdfiumAppendInputType;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssemblyCommand;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssemblyOperation;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageAssembler;

struct ScopedBitmapUnlock final {
  JNIEnv* env;
  jobject bitmap;

  ~ScopedBitmapUnlock() { AndroidBitmap_unlockPixels(env, bitmap); }
};

bool readFile(const std::string& path, std::vector<std::uint8_t>& bytes) {
  std::ifstream input(path, std::ios::binary | std::ios::ate);
  if (!input) return false;
  const auto end = input.tellg();
  const auto size = static_cast<std::streamoff>(end);
  if (size <= 0 || static_cast<std::uint64_t>(size) >
                      static_cast<std::uint64_t>((std::numeric_limits<int>::max)())) {
    return false;
  }
  bytes.resize(static_cast<std::size_t>(size));
  input.seekg(0, std::ios::beg);
  return static_cast<bool>(input.read(
      reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())));
}

bool readJavaPath(JNIEnv* env, jstring value, std::string& path) {
  if (value == nullptr) return false;
  const char* utf = env->GetStringUTFChars(value, nullptr);
  if (utf == nullptr) return false;
  path.assign(utf);
  env->ReleaseStringUTFChars(value, utf);
  return !path.empty();
}

}  // namespace

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumPageAssembler_nativeAssemble(
    JNIEnv* env,
    jclass,
    jstring inputPath,
    jint operation,
    jobjectArray appendPaths,
    jobjectArray appendBytes,
    jintArray appendTypes,
    jdoubleArray appendMetadata,
    jint pageIndex,
    jint destinationIndex,
    jstring scratchPath) {
  if (scratchPath == nullptr || pageIndex < 0 || destinationIndex < 0 ||
      operation < 0 || operation > 3 || (operation != 3 && inputPath == nullptr)) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                  "Invalid PDFium assembly request");
    return nullptr;
  }
  if (operation == 3 && inputPath != nullptr &&
      env->GetStringLength(inputPath) != 0) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                  "CREATE assembly must not have a current document");
    return nullptr;
  }

  std::string inputFilePath;
  std::vector<std::uint8_t> input;
  if (operation != 3 &&
      (!readJavaPath(env, inputPath, inputFilePath) ||
       !readFile(inputFilePath, input))) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                  "Unable to read PDFium assembly input");
    return nullptr;
  }

  const auto inputCount = appendBytes == nullptr
      ? 0
      : env->GetArrayLength(appendBytes);
  if (inputCount > 0 && (appendPaths == nullptr || appendTypes == nullptr ||
                         appendMetadata == nullptr ||
                         env->GetArrayLength(appendPaths) != inputCount ||
                         env->GetArrayLength(appendTypes) != inputCount ||
                         env->GetArrayLength(appendMetadata) != inputCount * 8)) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                  "PDFium assembly append metadata is inconsistent");
    return nullptr;
  }
  std::vector<jint> types(static_cast<std::size_t>(inputCount));
  if (inputCount > 0) {
    env->GetIntArrayRegion(appendTypes, 0, inputCount, types.data());
    if (env->ExceptionCheck()) return nullptr;
  }
  std::vector<jdouble> metadata(static_cast<std::size_t>(inputCount) * 8);
  if (!metadata.empty()) {
    env->GetDoubleArrayRegion(
        appendMetadata, 0, static_cast<jsize>(metadata.size()), metadata.data());
    if (env->ExceptionCheck()) return nullptr;
  }

  PdfiumPageAssemblyCommand command;
  command.operation = static_cast<PdfiumPageAssemblyOperation>(operation);
  command.pageIndex = static_cast<std::size_t>(pageIndex);
  command.destinationIndex = static_cast<std::size_t>(destinationIndex);
  command.appendInputs.reserve(static_cast<std::size_t>(inputCount));
  for (jsize index = 0; index < inputCount; ++index) {
    PdfiumAppendInput append;
    if (types[static_cast<std::size_t>(index)] == 0) {
      append.type = PdfiumAppendInputType::Pdf;
      auto* pathValue = static_cast<jstring>(
          env->GetObjectArrayElement(appendPaths, index));
      std::string path;
      const bool validPath = readJavaPath(env, pathValue, path);
      if (pathValue != nullptr) env->DeleteLocalRef(pathValue);
      if (!validPath || !readFile(path, append.bytes)) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                      "Unable to read PDF append input");
        return nullptr;
      }
    } else if (types[static_cast<std::size_t>(index)] == 1) {
      append.type = PdfiumAppendInputType::Image;
      auto* bytes = static_cast<jbyteArray>(
          env->GetObjectArrayElement(appendBytes, index));
      if (bytes == nullptr || env->GetArrayLength(bytes) <= 0) {
        if (bytes != nullptr) env->DeleteLocalRef(bytes);
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                      "PDFium image append input is empty");
        return nullptr;
      }
      const auto length = env->GetArrayLength(bytes);
      append.bytes.resize(static_cast<std::size_t>(length));
      env->GetByteArrayRegion(
          bytes, 0, length, reinterpret_cast<jbyte*>(append.bytes.data()));
      env->DeleteLocalRef(bytes);
      if (env->ExceptionCheck()) return nullptr;
    } else {
      env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                    "PDFium append input type is invalid");
      return nullptr;
    }
    const auto offset = static_cast<std::size_t>(index) * 8;
    append.pageWidth = metadata[offset];
    append.pageHeight = metadata[offset + 1];
    append.placement = {
        metadata[offset + 2], metadata[offset + 3], metadata[offset + 4],
        metadata[offset + 5], metadata[offset + 6], metadata[offset + 7]};
    command.appendInputs.push_back(std::move(append));
  }

  const char* utfPath = env->GetStringUTFChars(scratchPath, nullptr);
  if (utfPath == nullptr) return nullptr;
  const std::string scratch(utfPath);
  env->ReleaseStringUTFChars(scratchPath, utfPath);
  const auto result = PdfiumPageAssembler::assemble(
      std::move(input), std::move(command), scratch);
  if (!result) {
    const auto message = result.error.message.empty()
        ? "PDFium page assembly failed"
        : result.error.message;
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),
                  message.c_str());
    return nullptr;
  }
  if (result.pages.size() >
      static_cast<std::size_t>((std::numeric_limits<jsize>::max)() / 3)) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),
                  "PDFium assembly returned too many pages");
    return nullptr;
  }
  const auto values = env->NewDoubleArray(
      static_cast<jsize>(result.pages.size() * 3));
  if (values == nullptr) return nullptr;
  std::vector<jdouble> flattened;
  flattened.reserve(result.pages.size() * 3);
  for (const auto& page : result.pages) {
    flattened.push_back(page.width);
    flattened.push_back(page.height);
    flattened.push_back(static_cast<jdouble>(page.rotation));
  }
  env->SetDoubleArrayRegion(
      values, 0, static_cast<jsize>(flattened.size()), flattened.data());
  return values;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumRenderSession_nativeOpen(
    JNIEnv* env,
    jclass,
    jbyteArray documentBytes,
    jstring fallbackPath,
    jdouble fallbackCollectionIndex) {
  if (documentBytes == nullptr) return 0;
  const auto length = env->GetArrayLength(documentBytes);
  if (length <= 0) return 0;

  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
  env->GetByteArrayRegion(
      documentBytes, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
  if (env->ExceptionCheck()) return 0;

  std::optional<margelo::nitro::inksignpdf::pdfium::PdfiumFallbackFont>
      fallbackFont;
  if (fallbackPath != nullptr) {
    if (!std::isfinite(fallbackCollectionIndex) ||
        fallbackCollectionIndex < 0.0 ||
        std::floor(fallbackCollectionIndex) != fallbackCollectionIndex ||
        fallbackCollectionIndex >
            static_cast<double>((std::numeric_limits<std::size_t>::max)())) {
      env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                    "Fallback font collectionIndex must be a non-negative integer");
      return 0;
    }
    const char* utfPath = env->GetStringUTFChars(fallbackPath, nullptr);
    if (utfPath == nullptr) return 0;
    fallbackFont = margelo::nitro::inksignpdf::pdfium::PdfiumFallbackFont{
        utfPath, static_cast<std::size_t>(fallbackCollectionIndex)};
    env->ReleaseStringUTFChars(fallbackPath, utfPath);
  }

  auto opened = PdfiumDocumentSession::open(
      std::move(bytes), {}, std::move(fallbackFont));
  if (!opened) {
    const auto exceptionClass =
        (opened.error.code ==
                 margelo::nitro::inksignpdf::pdfium::PdfiumErrorCode::InvalidInput ||
         opened.error.code ==
                 margelo::nitro::inksignpdf::pdfium::PdfiumErrorCode::InvalidFallbackFont)
            ? "java/lang/IllegalArgumentException"
            : "java/lang/IllegalStateException";
    const auto message = opened.error.message.empty()
        ? "PDFium document open failed"
        : opened.error.message;
    env->ThrowNew(env->FindClass(exceptionClass), message.c_str());
    return 0;
  }
  return reinterpret_cast<jlong>(opened.session.release());
}

extern "C" JNIEXPORT jint JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumRenderSession_nativePageCount(
    JNIEnv*, jclass, jlong handle) {
  const auto* session = reinterpret_cast<const PdfiumDocumentSession*>(handle);
  if (session == nullptr) return 0;
  const auto count = session->pageCount();
  if (count > static_cast<std::size_t>(std::numeric_limits<jint>::max())) return 0;
  return static_cast<jint>(count);
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumRenderSession_nativePageDimensions(
    JNIEnv* env, jclass, jlong handle, jint pageIndex) {
  const auto* session = reinterpret_cast<const PdfiumDocumentSession*>(handle);
  assert(session != nullptr);

  PdfiumPageMetadata metadata;
  if (!session->inspectPage(static_cast<std::size_t>(pageIndex), metadata)) {
    return nullptr;
  }
  const auto dimensions = env->NewDoubleArray(2);
  if (dimensions == nullptr) return nullptr;
  const jdouble values[] = {metadata.width, metadata.height};
  env->SetDoubleArrayRegion(dimensions, 0, 2, values);
  return dimensions;
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumRenderSession_nativeHorizontalSnapCandidates(
    JNIEnv* env, jclass, jlong handle, jint pageIndex) {
  const auto* session = reinterpret_cast<const PdfiumDocumentSession*>(handle);
  assert(session != nullptr);
  std::vector<margelo::nitro::inksignpdf::pdfium::PdfiumHorizontalSnapCandidate>
      candidates;
  if (!session->inspectHorizontalSnapCandidates(
          static_cast<std::size_t>(pageIndex), candidates)) {
    return nullptr;
  }
  if (candidates.size() >
      static_cast<std::size_t>((std::numeric_limits<jsize>::max)() / 3)) {
    return nullptr;
  }
  const auto values = env->NewDoubleArray(static_cast<jsize>(candidates.size() * 3));
  if (values == nullptr) return nullptr;
  std::vector<jdouble> flattened;
  flattened.reserve(candidates.size() * 3);
  for (const auto& candidate : candidates) {
    flattened.push_back(candidate.left);
    flattened.push_back(candidate.right);
    flattened.push_back(candidate.y);
  }
  env->SetDoubleArrayRegion(
      values, 0, static_cast<jsize>(flattened.size()), flattened.data());
  return values;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumRenderSession_nativeRenderPageIntoBitmap(
    JNIEnv* env,
    jclass,
    jlong handle,
    jint pageIndex,
    jobject bitmap,
    jdouble a,
    jdouble b,
    jdouble c,
    jdouble d,
    jdouble e,
    jdouble f,
    jdouble clipLeft,
    jdouble clipTop,
    jdouble clipRight,
    jdouble clipBottom,
    jint background,
    jint flags) {
  const auto* session = reinterpret_cast<const PdfiumDocumentSession*>(handle);
  if (session == nullptr || pageIndex < 0 || bitmap == nullptr) {
    return JNI_FALSE;
  }

  AndroidBitmapInfo info{};
  if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
      info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.width == 0 ||
      info.height == 0 || info.stride < info.width * 4) {
    return JNI_FALSE;
  }

  void* pixels = nullptr;
  if (AndroidBitmap_lockPixels(env, bitmap, &pixels) !=
      ANDROID_BITMAP_RESULT_SUCCESS) {
    return JNI_FALSE;
  }
  const ScopedBitmapUnlock unlock{env, bitmap};
  if (pixels == nullptr) return JNI_FALSE;

  PdfiumPageRenderRequest request;
  request.pageIndex = static_cast<std::size_t>(pageIndex);
  request.width = static_cast<std::int32_t>(info.width);
  request.height = static_cast<std::int32_t>(info.height);
  request.stride = static_cast<std::int32_t>(info.stride);
  request.pageToDevice = {a, b, c, d, e, f};
  request.clip = {clipLeft, clipTop, clipRight, clipBottom};
  request.background = static_cast<std::uint32_t>(background);
  request.flags = static_cast<std::uint32_t>(flags);
  request.bgra = std::span<std::uint8_t>(
      static_cast<std::uint8_t*>(pixels),
      static_cast<std::size_t>(info.stride) *
           static_cast<std::size_t>(info.height));

  const auto error = session->renderPage(request);
  return error.ok() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_margelo_nitro_inksignpdf_PdfiumRenderSession_nativeClose(
    JNIEnv*, jclass, jlong handle) {
  auto* session = reinterpret_cast<PdfiumDocumentSession*>(handle);
  if (session == nullptr) return;
  session->close();
  delete session;
}
