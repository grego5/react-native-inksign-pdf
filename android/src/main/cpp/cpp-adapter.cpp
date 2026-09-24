#include <fbjni/fbjni.h>
#include <cstddef>
#include <cstdint>
#include <vector>
#include "InkEngineJni.hpp"
#include "ReactNativeInkSignPdfOnLoad.hpp"

extern "C" bool ReactNativeInkSignPdfPdfiumSmoke();
extern "C" bool ReactNativeInkSignPdfPdfiumSessionLifecycleSmoke();
extern "C" bool ReactNativeInkSignPdfPdfiumAssemblySmoke(
    const char*, const std::uint8_t*, std::size_t);

extern "C" JNIEXPORT jboolean JNICALL
Java_com_margelo_nitro_inksignpdf_NativeTestRuntime_pdfiumSmokeNative(
    JNIEnv*, jclass) {
  return ReactNativeInkSignPdfPdfiumSmoke() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_margelo_nitro_inksignpdf_NativeTestRuntime_pdfiumSessionLifecycleNative(
    JNIEnv*, jclass) {
  return ReactNativeInkSignPdfPdfiumSessionLifecycleSmoke() ? JNI_TRUE
                                                            : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_margelo_nitro_inksignpdf_NativeTestRuntime_pdfiumAssemblyNative(
    JNIEnv* environment,
    jclass,
    jstring scratchPath,
    jbyteArray jpegBytes) {
  if (scratchPath == nullptr || jpegBytes == nullptr) return JNI_FALSE;
  const char* pathChars = environment->GetStringUTFChars(scratchPath, nullptr);
  if (pathChars == nullptr) return JNI_FALSE;

  const jsize length = environment->GetArrayLength(jpegBytes);
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
  if (length > 0) {
    environment->GetByteArrayRegion(
        jpegBytes, 0, length, reinterpret_cast<jbyte*>(bytes.data()));
  }
  const bool result = ReactNativeInkSignPdfPdfiumAssemblySmoke(
      pathChars, bytes.data(), bytes.size());
  environment->ReleaseStringUTFChars(scratchPath, pathChars);
  return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::inksignpdf::registerAllNatives();
    margelo::nitro::inksignpdf::JInkEngine::registerNatives();
  });
}
