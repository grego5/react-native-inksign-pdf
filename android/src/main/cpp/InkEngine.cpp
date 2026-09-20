#include "InkEngine.hpp"

#include <cstring>
#include <array>
#include <limits>
#include <new>

#include "core/PerfettoTrace.hpp"

namespace margelo::nitro::inksignpdf {

namespace {

using detail::ScopedPerfettoTrace;

constexpr std::uint32_t kFrameMagic = 0x4E534546;  // "NSEF"
constexpr std::uint32_t kFrameVersion = 15;
constexpr std::size_t kFrameHeaderBytes = 456;
constexpr std::size_t kCubicSegmentBytes = sizeof(double) * 8 + sizeof(std::uint64_t) * 2;
constexpr std::size_t kContourRecordBytes = sizeof(std::uint64_t) * 4 + sizeof(std::uint32_t) * 2;
constexpr jint kInvalidFrameBuffer = -InkEngineStatusInvalidInput;
constexpr jint kFrameSizeOverflow = -InkEngineStatusException;
constexpr jint kMutationErrorBase = -1000;
constexpr std::size_t kInputValueCount = 6;
constexpr std::size_t kInputBytes = kInputValueCount * sizeof(double);
constexpr std::size_t kMaxRealInputs = INK_ENGINE_MAX_REAL_INPUT_BATCH;

struct InputValues {
  double x;
  double y;
  double time;
  double pressure;
  double tilt;
  double orientation;
};

constexpr double kMillisToSeconds = 0.001;

InkEngineInput makeInput(const InputValues& values) noexcept {
  return {.x = values.x,
          .y = values.y,
          .time = values.time * kMillisToSeconds,
          .pressure = values.pressure,
          .tilt = values.tilt,
          .orientation = values.orientation};
}

bool checkedAdd(std::size_t left, std::size_t right, std::size_t& result) {
  if (right > std::numeric_limits<std::size_t>::max() - left) return false;
  result = left + right;
  return true;
}

bool checkedSegmentBytes(std::size_t count, std::size_t& result) {
  if (count > std::numeric_limits<std::size_t>::max() /
                  kCubicSegmentBytes) {
    return false;
  }
  result = count * kCubicSegmentBytes;
  return true;
}

bool checkedFrameBytes(
    const InkEngineFrameView& frame,
    std::size_t& result) {
  std::size_t segmentCount = 0;
  if (!checkedAdd(segmentCount, frame.segmentCount, segmentCount)) return false;
  std::size_t contourBytes = 0;
  if (frame.contourCount > std::numeric_limits<std::size_t>::max() /
          kContourRecordBytes ||
      !checkedAdd(0, frame.contourCount * kContourRecordBytes, contourBytes))
    return false;

  std::size_t segmentBytes = 0;
  if (!checkedSegmentBytes(segmentCount, segmentBytes) ||
      !checkedAdd(kFrameHeaderBytes, segmentBytes, result) ||
      !checkedAdd(result, contourBytes, result)) {
    return false;
  }
  return true;
}

template <typename Value>
void writeValue(std::uint8_t*& cursor, Value value) noexcept {
  std::memcpy(cursor, &value, sizeof(Value));
  cursor += sizeof(Value);
}

void writeSegments(std::uint8_t*& cursor,
                   const InkEngineCubicSegment* segments,
                   std::size_t count) noexcept {
  for (std::size_t index = 0; index < count; ++index) {
    const auto& segment = segments[index];
    writeValue(cursor, segment.p0.x); writeValue(cursor, segment.p0.y);
    writeValue(cursor, segment.c1.x); writeValue(cursor, segment.c1.y);
    writeValue(cursor, segment.c2.x); writeValue(cursor, segment.c2.y);
    writeValue(cursor, segment.p3.x); writeValue(cursor, segment.p3.y);
    writeValue(cursor, static_cast<std::uint64_t>(segment.sourceStart));
    writeValue(cursor, static_cast<std::uint64_t>(segment.sourceEnd));
  }
}

void serializeFrame(
    const InkEngineFrameView& frame,
    std::uint8_t* destination) noexcept {
  std::uint8_t* cursor = destination;
  writeValue(cursor, kFrameMagic);
  writeValue(cursor, kFrameVersion);
  writeValue(cursor, frame.type);
  writeValue(cursor, std::uint32_t{0});
  writeValue(cursor, frame.revision);
  writeValue(cursor, frame.committedPointCount);
  writeValue(cursor, static_cast<std::uint64_t>(frame.segmentCount));
  writeValue(cursor, static_cast<std::uint64_t>(frame.contourCount));
  const auto& diagnostics = frame.diagnostics;
  writeValue(cursor, diagnostics.validityFlags);
  writeValue(cursor, static_cast<std::uint32_t>(diagnostics.suppressionReason));
  writeValue(cursor, diagnostics.queuedRealInputCount);
  writeValue(cursor, diagnostics.processedRealInputCount);
  writeValue(cursor, diagnostics.queuedPredictedInputCount);
  writeValue(cursor, diagnostics.processedPredictedInputCount);
  writeValue(cursor, diagnostics.stableModeledInputCount);
  writeValue(cursor, diagnostics.realModeledInputCount);
  writeValue(cursor, diagnostics.fullModeledInputCount);
  writeValue(cursor, diagnostics.realMovingSpeed);
  writeValue(cursor, diagnostics.realNormalizedSpeed);
  writeValue(cursor, diagnostics.predictedMovingSpeed);
  writeValue(cursor, diagnostics.predictedNormalizedSpeed);
  const InkEnginePoint points[] = {
      {diagnostics.latestRealRawInput.x, diagnostics.latestRealRawInput.y},
      {diagnostics.latestPlatformPredictedRawInput.x,
       diagnostics.latestPlatformPredictedRawInput.y},
      {diagnostics.stableModeledTip.x, diagnostics.stableModeledTip.y},
      {diagnostics.realModeledTip.x, diagnostics.realModeledTip.y},
      {diagnostics.predictedModeledEndpoint.x,
       diagnostics.predictedModeledEndpoint.y},
      {diagnostics.terminalLeftEndpoint.x, diagnostics.terminalLeftEndpoint.y},
      {diagnostics.terminalRightEndpoint.x, diagnostics.terminalRightEndpoint.y},
      {diagnostics.renderedPredictionEndpoint.x,
       diagnostics.renderedPredictionEndpoint.y},
  };
  for (const auto& point : points) {
    writeValue(cursor, point.x);
    writeValue(cursor, point.y);
  }
  writeValue(cursor, diagnostics.latestRealRawTime);
  writeValue(cursor, diagnostics.latestPlatformPredictedRawTime);
  writeValue(cursor, diagnostics.stableModeledTime);
  writeValue(cursor, diagnostics.realModeledTime);
  writeValue(cursor, diagnostics.predictedModeledTime);
  writeValue(cursor, diagnostics.renderedPredictionTime);
  writeValue(cursor, diagnostics.realElapsedTime);
  writeValue(cursor, diagnostics.fullElapsedTime);
  writeValue(cursor, diagnostics.completeElapsedTime);
  writeValue(cursor, diagnostics.inputAgeAtReplacement);
  writeValue(cursor, diagnostics.platformPredictionTemporalLead);
  writeValue(cursor, diagnostics.modeledPredictionTemporalLead);
  writeValue(cursor, diagnostics.renderedPredictionTemporalLead);
  writeValue(cursor, diagnostics.platformPredictionLongitudinalLead);
  writeValue(cursor, diagnostics.modeledPredictionLongitudinalLead);
  writeValue(cursor, diagnostics.renderedPredictionLongitudinalLead);
  writeValue(cursor, diagnostics.platformPredictionLateralError);
  writeValue(cursor, diagnostics.modeledPredictionLateralError);
  writeValue(cursor, diagnostics.renderedPredictionLateralError);
  writeValue(cursor, diagnostics.modelDurationNanos);
  writeValue(cursor, diagnostics.geometryDurationNanos);
  writeValue(cursor, diagnostics.rendererReplacementDurationNanos);
  writeValue(cursor, diagnostics.rendererDrawDurationNanos);
  writeSegments(cursor, frame.segments, frame.segmentCount);
  for (std::size_t index = 0; index < frame.contourCount; ++index) {
    const auto& contour = frame.contours[index];
    writeValue(cursor, static_cast<std::uint64_t>(contour.segmentStart));
    writeValue(cursor, static_cast<std::uint64_t>(contour.segmentCount));
    writeValue(cursor, static_cast<std::uint64_t>(contour.sourceStart));
    writeValue(cursor, static_cast<std::uint64_t>(contour.sourceEnd));
    writeValue(cursor, contour.closed ? std::uint32_t{1} : std::uint32_t{0});
    writeValue(cursor, std::uint32_t{0});
  }
}

jint toJInt(std::size_t value) noexcept {
  constexpr auto max = static_cast<std::size_t>(std::numeric_limits<jint>::max());
  return value > max ? kFrameSizeOverflow : static_cast<jint>(value);
}

}  // namespace

JInkEngine::JInkEngine()
    : engine_(ink_engine_create()) {
  if (engine_ == nullptr) throw std::bad_alloc();
}

JInkEngine::~JInkEngine() { close(); }

jint JInkEngine::configurePen(
    jdouble minWidth,
    jdouble maxWidth,
    jdouble smoothing,
    jdouble logicalDisplayUnitsPerPageUnit) noexcept {
  return ink_engine_configure_pen(
      engine_, minWidth, maxWidth, smoothing,
      logicalDisplayUnitsPerPageUnit);
}

void JInkEngine::cancel() noexcept {
  ink_engine_cancel(engine_);
}

namespace {

jint copyFrameImpl(
    InkEngineRef engine,
    jni::alias_ref<jni::JByteBuffer> buffer) noexcept {
  const auto* frame = ink_engine_frame(engine);
  if (frame == nullptr) return kInvalidFrameBuffer;

  std::size_t requiredBytes = 0;
  if (!checkedFrameBytes(*frame, requiredBytes)) return kFrameSizeOverflow;
  const auto required = toJInt(requiredBytes);
  if (required < 0) return required;
  if (buffer == nullptr) return kInvalidFrameBuffer;

  auto* environment = jni::Environment::current();
  const auto capacity = environment->GetDirectBufferCapacity(buffer.get());
  auto* destination = static_cast<std::uint8_t*>(
      environment->GetDirectBufferAddress(buffer.get()));
  if (capacity < 0 || destination == nullptr) return kInvalidFrameBuffer;
  if (capacity < required) return required;

  serializeFrame(*frame, destination);
  detail::perfettoCounter("InkSign C++ serialized frame bytes", requiredBytes);
  return 0;
}

}  // namespace

jint JInkEngine::copyFrame(
    jni::alias_ref<jni::JByteBuffer> buffer) noexcept {
  ScopedPerfettoTrace trace("InkSign/C++ frame copy");
  return copyFrameImpl(engine_, buffer);
}

jint JInkEngine::mutateAndCopy(
    jint operation,
    jdouble x,
    jdouble y,
    jdouble time,
    jdouble pressure,
    jdouble tilt,
    jdouble orientation,
    jni::alias_ref<jni::JByteBuffer> buffer) noexcept {
  ScopedPerfettoTrace trace("InkSign/C++ mutate+frame");
  const auto input = makeInput({x, y, time, pressure, tilt, orientation});
  jint status = InkEngineStatusInvalidInput;
  switch (operation) {
    case 0:
      status = ink_engine_begin(engine_, input);
      break;
    case 1:
      status = ink_engine_update(engine_, input);
      break;
    case 2:
      status = ink_engine_end(engine_, input);
      break;
    default:
      return kMutationErrorBase - InkEngineStatusInvalidInput;
  }
  if (status != InkEngineStatusOk) {
    return kMutationErrorBase - status;
  }
  ScopedPerfettoTrace frameTrace("InkSign/C++ frame copy");
  return copyFrameImpl(engine_, buffer);
}

jint JInkEngine::mutateBatchAndCopy(
    jint operation,
    jni::alias_ref<jni::JByteBuffer> inputBuffer,
    jint inputCount,
    jni::alias_ref<jni::JByteBuffer> buffer) noexcept {
  ScopedPerfettoTrace trace("InkSign/C++ real batch mutation");
  if (inputCount <= 0 || static_cast<std::size_t>(inputCount) > kMaxRealInputs ||
      (operation != INK_ENGINE_BATCH_OPERATION_UPDATE &&
       operation != INK_ENGINE_BATCH_OPERATION_END) || inputBuffer == nullptr) {
    return kMutationErrorBase - InkEngineStatusInvalidInput;
  }

  auto* environment = jni::Environment::current();
  const auto capacity = environment->GetDirectBufferCapacity(inputBuffer.get());
  const auto* source = static_cast<const std::uint8_t*>(
      environment->GetDirectBufferAddress(inputBuffer.get()));
  const auto requiredBytes = static_cast<std::size_t>(inputCount) * kInputBytes;
  if (capacity < 0 || source == nullptr ||
      static_cast<std::size_t>(capacity) < requiredBytes) {
    return kMutationErrorBase - InkEngineStatusInvalidInput;
  }

  std::array<InkEngineInput, kMaxRealInputs> inputs{};
  for (std::size_t index = 0; index < static_cast<std::size_t>(inputCount);
       ++index) {
    InputValues values{};
    const auto* cursor = source + index * kInputBytes;
    std::memcpy(&values.x, cursor, sizeof(double)); cursor += sizeof(double);
    std::memcpy(&values.y, cursor, sizeof(double)); cursor += sizeof(double);
    std::memcpy(&values.time, cursor, sizeof(double)); cursor += sizeof(double);
    std::memcpy(&values.pressure, cursor, sizeof(double)); cursor += sizeof(double);
    std::memcpy(&values.tilt, cursor, sizeof(double)); cursor += sizeof(double);
    std::memcpy(&values.orientation, cursor, sizeof(double));
    inputs[index] = makeInput(values);
  }

  const auto status = ink_engine_mutate_batch(
      engine_, static_cast<std::uint32_t>(operation), inputs.data(),
      static_cast<std::size_t>(inputCount));
  if (status != InkEngineStatusOk) return kMutationErrorBase - status;
  ScopedPerfettoTrace frameTrace("InkSign/C++ frame copy");
  return copyFrameImpl(engine_, buffer);
}

jint JInkEngine::replacePredictedInputs(
    jni::alias_ref<jni::JByteBuffer> inputBuffer,
    jint inputCount,
    jdouble currentTime,
    jni::alias_ref<jni::JByteBuffer> buffer) noexcept {
  ScopedPerfettoTrace trace("InkSign/C++ replace prediction");
  constexpr std::size_t kInputValueCount = 6;
  constexpr std::size_t kInputBytes = kInputValueCount * sizeof(double);
  constexpr std::size_t kMaxInputs = 64;
  if (inputCount < 0 || static_cast<std::size_t>(inputCount) > kMaxInputs ||
      inputBuffer == nullptr) {
    return kMutationErrorBase - InkEngineStatusInvalidInput;
  }

  auto* environment = jni::Environment::current();
  const auto capacity = environment->GetDirectBufferCapacity(inputBuffer.get());
  const auto* source = static_cast<const std::uint8_t*>(
      environment->GetDirectBufferAddress(inputBuffer.get()));
  const auto requiredBytes = static_cast<std::size_t>(inputCount) * kInputBytes;
  if (capacity < 0 || source == nullptr ||
      static_cast<std::size_t>(capacity) < requiredBytes) {
    return kMutationErrorBase - InkEngineStatusInvalidInput;
  }

  std::array<InkEngineInput, kMaxInputs> inputs{};
  for (std::size_t index = 0; index < static_cast<std::size_t>(inputCount);
       ++index) {
    InputValues values{};
    const auto* cursor = source + index * kInputBytes;
    std::memcpy(&values.x, cursor, sizeof(double));
    cursor += sizeof(double);
    std::memcpy(&values.y, cursor, sizeof(double));
    cursor += sizeof(double);
    std::memcpy(&values.time, cursor, sizeof(double));
    cursor += sizeof(double);
    std::memcpy(&values.pressure, cursor, sizeof(double));
    cursor += sizeof(double);
    std::memcpy(&values.tilt, cursor, sizeof(double));
    cursor += sizeof(double);
    std::memcpy(&values.orientation, cursor, sizeof(double));
    inputs[index] = makeInput(values);
  }

  const auto status = ink_engine_replace_predicted_inputs(
      engine_, inputs.data(), static_cast<std::size_t>(inputCount),
      currentTime * kMillisToSeconds);
  if (status != InkEngineStatusOk) {
    return kMutationErrorBase - status;
  }
  ScopedPerfettoTrace frameTrace("InkSign/C++ frame copy");
  return copyFrameImpl(engine_, buffer);
}

void JInkEngine::close() noexcept {
  if (engine_ == nullptr) return;
  ink_engine_destroy(engine_);
  engine_ = nullptr;
}

void JInkEngine::registerNatives() {
  registerHybrid({
      makeNativeMethod("initHybrid", JInkEngine::initHybrid),
      makeNativeMethod(
          "configurePenNative", JInkEngine::configurePen),
      makeNativeMethod("cancelNative", JInkEngine::cancel),
      makeNativeMethod("copyFrameNative", JInkEngine::copyFrame),
      makeNativeMethod(
          "mutateAndCopyNative", JInkEngine::mutateAndCopy),
      makeNativeMethod(
          "mutateBatchAndCopyNative", JInkEngine::mutateBatchAndCopy),
      makeNativeMethod(
          "replacePredictedInputsNative",
          JInkEngine::replacePredictedInputs),
      makeNativeMethod("closeNative", JInkEngine::close),
  });
}

}  // namespace margelo::nitro::inksignpdf
