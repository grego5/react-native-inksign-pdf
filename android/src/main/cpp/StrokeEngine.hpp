#pragma once

#include "StrokeEngineC.h"

#include <fbjni/ByteBuffer.h>
#include <fbjni/fbjni.h>

#include <cstddef>
#include <cstdint>

namespace margelo::nitro::inksignpdf {

using namespace facebook;

/**
 * Handwritten fbjni owner for the Android stroke-engine path.
 *
 * The Kotlin object owns this C++ instance through HybridData. Engine frames
 * are copied into a caller-owned direct ByteBuffer before the next mutation.
 */
class JStrokeEngine final : public jni::HybridClass<JStrokeEngine> {
 public:
  static constexpr auto kJavaDescriptor =
      "Lcom/margelo/nitro/inksignpdf/StrokeEngine;";

  static jni::local_ref<jhybriddata> initHybrid(
      jni::alias_ref<jhybridobject>) {
    return makeCxxInstance();
  }

  jint configurePen(
      jdouble minWidth,
      jdouble maxWidth,
      jdouble smoothing,
      jdouble logicalDisplayUnitsPerPageUnit) noexcept;
  void cancel() noexcept;
  jint copyFrame(jni::alias_ref<jni::JByteBuffer> buffer) noexcept;
  jint mutateAndCopy(
      jint operation,
      jdouble x,
      jdouble y,
      jdouble time,
      jdouble pressure,
      jdouble tilt,
      jdouble orientation,
      jni::alias_ref<jni::JByteBuffer> buffer) noexcept;
  jint mutateBatchAndCopy(
      jint operation,
      jni::alias_ref<jni::JByteBuffer> inputBuffer,
      jint inputCount,
      jni::alias_ref<jni::JByteBuffer> buffer) noexcept;
  jint replacePredictedInputs(
      jni::alias_ref<jni::JByteBuffer> inputBuffer,
      jint inputCount,
      jdouble currentTime,
      jni::alias_ref<jni::JByteBuffer> buffer) noexcept;
  void close() noexcept;

  ~JStrokeEngine() override;

  static void registerNatives();

 private:
  friend HybridBase;

  JStrokeEngine();

  NSEStrokeEngineRef engine_ = nullptr;
};

}  // namespace margelo::nitro::inksignpdf
