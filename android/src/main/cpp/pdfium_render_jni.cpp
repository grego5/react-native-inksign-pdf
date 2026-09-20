#include <jni.h>

#include <android/bitmap.h>

#include <cstdint>
#include <cmath>
#include <limits>
#include <span>
#include <string>
#include <vector>

#include "pdfium-adapter/PdfiumDocumentSession.hpp"

namespace {

using margelo::nitro::inksignpdf::pdfium::PdfiumDocumentSession;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageMetadata;
using margelo::nitro::inksignpdf::pdfium::PdfiumPageRenderRequest;

struct ScopedBitmapUnlock final {
  JNIEnv* env;
  jobject bitmap;

  ~ScopedBitmapUnlock() { AndroidBitmap_unlockPixels(env, bitmap); }
};

}  // namespace

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
  if (session == nullptr || pageIndex < 0) return nullptr;

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
