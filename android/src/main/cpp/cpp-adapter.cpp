#include <fbjni/fbjni.h>
#include "StrokeEngine.hpp"
#include "ReactNativeInkSignPdfOnLoad.hpp"

extern "C" bool ReactNativeInkSignPdfPdfiumSmoke();

extern "C" JNIEXPORT jboolean JNICALL
Java_com_margelo_nitro_inksignpdf_NativeTestRuntime_pdfiumSmokeNative(
    JNIEnv*, jclass) {
  return ReactNativeInkSignPdfPdfiumSmoke() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::inksignpdf::registerAllNatives();
    margelo::nitro::inksignpdf::JStrokeEngine::registerNatives();
  });
}
