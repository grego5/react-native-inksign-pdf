#include <fbjni/fbjni.h>
#include "StrokeEngine.hpp"
#include "ReactNativeInkSignPdfOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::inksignpdf::registerAllNatives();
    margelo::nitro::inksignpdf::JStrokeEngine::registerNatives();
  });
}
