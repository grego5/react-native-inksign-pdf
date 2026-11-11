#include "InkEngineC.h"

#include "InkEngine.hpp"

#include <array>
#include <cmath>
#include <type_traits>
#include <utility>
#include <vector>

struct InkEngineOpaque {
  margelo::nitro::inksignpdf::InkEngine engine;
  margelo::nitro::inksignpdf::InkStrokeFrame frame;
  std::vector<InkEngineCubicSegment> segments;
  std::vector<InkEngineCubicContourRecord> contours;
  InkEngineFrameView view{};
};

namespace {

using namespace margelo::nitro::inksignpdf;
using TransportSegment = CubicSegment;

static_assert(kInkEngineApiVersion == INK_ENGINE_API_VERSION);
static_assert(sizeof(Vec2) == sizeof(InkEnginePoint));
static_assert(alignof(Vec2) == alignof(InkEnginePoint));
static_assert(std::is_standard_layout_v<Vec2>);
static_assert(std::is_standard_layout_v<InkEnginePoint>);
static_assert(sizeof(TransportSegment) == sizeof(InkEngineCubicSegment));
static_assert(alignof(TransportSegment) == alignof(InkEngineCubicSegment));
static_assert(std::is_standard_layout_v<TransportSegment>);

InkStrokeInput makeInput(InkStrokeEventType eventType, InkEngineInput input) noexcept {
  return {.eventType = eventType,
          .position = {input.x, input.y},
          .time = input.time,
          .pressure = input.pressure,
          .tilt = input.tilt,
          .orientation = input.orientation};
}

void clearView(InkEngineFrameView& view) noexcept { view = {}; }

void fillView(InkEngineOpaque* engine) {
  const auto& frame = engine->frame;
  engine->segments.clear();
  engine->contours.clear();
  std::size_t segmentCount = 0;
  for (const auto& contour : frame.contours) segmentCount += contour.path.segments.size();
  const auto segmentCapacity = engine->segments.capacity();
  const auto contourCapacity = engine->contours.capacity();
  engine->segments.reserve(segmentCount);
  engine->contours.reserve(frame.contours.size());
  if (engine->segments.capacity() > segmentCapacity)
    engine->engine.recordFrameFlatteningCapacityGrowth();
  if (engine->contours.capacity() > contourCapacity)
    engine->engine.recordFrameFlatteningCapacityGrowth();
  for (const auto& contour : frame.contours) {
    const std::size_t start = engine->segments.size();
    for (const auto& segment : contour.path.segments) {
      engine->segments.push_back({.p0 = {segment.p0.x, segment.p0.y},
                                  .c1 = {segment.c1.x, segment.c1.y},
                                  .c2 = {segment.c2.x, segment.c2.y},
                                  .p3 = {segment.p3.x, segment.p3.y},
                                  .sourceStart = segment.sourceStart,
                                  .sourceEnd = segment.sourceEnd});
    }
    engine->contours.push_back({.segmentStart = start,
                                .segmentCount = contour.path.segments.size(),
                                .sourceStart = contour.sourceStart,
                                .sourceEnd = contour.sourceEnd,
                                .closed = contour.path.closed ? 1u : 0u});
  }

  auto& view = engine->view;
  clearView(view);
  view.type = static_cast<uint32_t>(frame.type);
  view.revision = frame.revision;
  view.committedPointCount = frame.committedPointCount;
  view.segments = engine->segments.empty() ? nullptr : engine->segments.data();
  view.segmentCount = engine->segments.size();
  view.contours = engine->contours.empty() ? nullptr : engine->contours.data();
  view.contourCount = engine->contours.size();
  const auto& diagnostics = frame.diagnostics;
  view.diagnostics.validityFlags = diagnostics.validityFlags;
  view.diagnostics.suppressionReason = static_cast<uint32_t>(diagnostics.suppressionReason);
  view.diagnostics.queuedRealInputCount = diagnostics.queuedRealInputCount;
  view.diagnostics.processedRealInputCount = diagnostics.processedRealInputCount;
  view.diagnostics.queuedPredictedInputCount = diagnostics.queuedPredictedInputCount;
  view.diagnostics.processedPredictedInputCount = diagnostics.processedPredictedInputCount;
  view.diagnostics.stableModeledInputCount = diagnostics.stableModeledInputCount;
  view.diagnostics.realModeledInputCount = diagnostics.realModeledInputCount;
  view.diagnostics.fullModeledInputCount = diagnostics.fullModeledInputCount;
  view.diagnostics.realMovingSpeed = diagnostics.realMovingSpeed;
  view.diagnostics.realNormalizedSpeed = diagnostics.realNormalizedSpeed;
  view.diagnostics.predictedMovingSpeed = diagnostics.predictedMovingSpeed;
  view.diagnostics.predictedNormalizedSpeed = diagnostics.predictedNormalizedSpeed;
  view.diagnostics.latestRealRawInput = {diagnostics.latestRealRawInput.x, diagnostics.latestRealRawInput.y};
  view.diagnostics.latestPlatformPredictedRawInput = {diagnostics.latestPlatformPredictedRawInput.x, diagnostics.latestPlatformPredictedRawInput.y};
  view.diagnostics.stableModeledTip = {diagnostics.stableModeledTip.x, diagnostics.stableModeledTip.y};
  view.diagnostics.realModeledTip = {diagnostics.realModeledTip.x, diagnostics.realModeledTip.y};
  view.diagnostics.predictedModeledEndpoint = {diagnostics.predictedModeledEndpoint.x, diagnostics.predictedModeledEndpoint.y};
  view.diagnostics.terminalLeftEndpoint = {diagnostics.terminalLeftEndpoint.x, diagnostics.terminalLeftEndpoint.y};
  view.diagnostics.terminalRightEndpoint = {diagnostics.terminalRightEndpoint.x, diagnostics.terminalRightEndpoint.y};
  view.diagnostics.renderedPredictionEndpoint = {diagnostics.renderedPredictionEndpoint.x, diagnostics.renderedPredictionEndpoint.y};
  view.diagnostics.latestRealRawTime = diagnostics.latestRealRawTime;
  view.diagnostics.latestPlatformPredictedRawTime = diagnostics.latestPlatformPredictedRawTime;
  view.diagnostics.stableModeledTime = diagnostics.stableModeledTime;
  view.diagnostics.realModeledTime = diagnostics.realModeledTime;
  view.diagnostics.predictedModeledTime = diagnostics.predictedModeledTime;
  view.diagnostics.renderedPredictionTime = diagnostics.renderedPredictionTime;
  view.diagnostics.realElapsedTime = diagnostics.realElapsedTime;
  view.diagnostics.fullElapsedTime = diagnostics.fullElapsedTime;
  view.diagnostics.completeElapsedTime = diagnostics.completeElapsedTime;
  view.diagnostics.inputAgeAtReplacement = diagnostics.inputAgeAtReplacement;
  view.diagnostics.platformPredictionTemporalLead = diagnostics.platformPredictionTemporalLead;
  view.diagnostics.modeledPredictionTemporalLead = diagnostics.modeledPredictionTemporalLead;
  view.diagnostics.renderedPredictionTemporalLead = diagnostics.renderedPredictionTemporalLead;
  view.diagnostics.platformPredictionLongitudinalLead = diagnostics.platformPredictionLongitudinalLead;
  view.diagnostics.modeledPredictionLongitudinalLead = diagnostics.modeledPredictionLongitudinalLead;
  view.diagnostics.renderedPredictionLongitudinalLead = diagnostics.renderedPredictionLongitudinalLead;
  view.diagnostics.platformPredictionLateralError = diagnostics.platformPredictionLateralError;
  view.diagnostics.modeledPredictionLateralError = diagnostics.modeledPredictionLateralError;
  view.diagnostics.renderedPredictionLateralError = diagnostics.renderedPredictionLateralError;
  view.diagnostics.modelDurationNanos = diagnostics.modelDurationNanos;
  view.diagnostics.geometryDurationNanos = diagnostics.geometryDurationNanos;
  view.diagnostics.rendererReplacementDurationNanos = diagnostics.rendererReplacementDurationNanos;
  view.diagnostics.rendererDrawDurationNanos = diagnostics.rendererDrawDurationNanos;
}

template <typename Call>
int32_t invoke(InkEngineRef ref, const Call& call) noexcept {
  if (ref == nullptr) return InkEngineStatusInvalidInput;
  try {
    const int32_t result = static_cast<int32_t>(call(ref).code);
    fillView(ref);
    return result;
  } catch (...) {
    ref->frame = {};
    ref->segments.clear();
    ref->contours.clear();
    clearView(ref->view);
    return InkEngineStatusException;
  }
}

void installPredictionFrame(InkEngineOpaque* engine,
                            InkStrokePredictionFrame prediction) {
  engine->frame = {};
  engine->frame.type = InkStrokeFrameType::Prediction;
  engine->frame.diagnostics = prediction.diagnostics;
  engine->frame.contours = std::move(prediction.contours);
  fillView(engine);
}

}  // namespace

extern "C" {

InkEngineRef ink_engine_create(void) noexcept {
  try {
    auto* engine = new InkEngineOpaque();
    fillView(engine);
    return engine;
  } catch (...) {
    return nullptr;
  }
}

void ink_engine_destroy(InkEngineRef engine) noexcept { delete engine; }

int32_t ink_engine_configure_pen(InkEngineRef engine,
                                        double min_width, double max_width,
                                        double smoothing,
                                        double logical_display_units_per_page_unit) noexcept {
  if (engine == nullptr || !std::isfinite(min_width) || !std::isfinite(max_width) ||
      !std::isfinite(smoothing) || !std::isfinite(logical_display_units_per_page_unit) ||
      min_width <= 0.0 || max_width <= 0.0 || min_width > max_width ||
      smoothing < 0.0 || smoothing > 1.0 || logical_display_units_per_page_unit <= 0.0)
    return InkEngineStatusInvalidInput;
  return invoke(engine, [&](InkEngineOpaque* value) {
    auto config = value->engine.config();
    config.minWidth = min_width;
    config.maxWidth = max_width;
    config.smoothing = smoothing;
    config.logicalDisplayUnitsPerPageUnit = logical_display_units_per_page_unit;
    return value->engine.setConfig(config);
  });
}

int32_t ink_engine_begin(InkEngineRef engine, InkEngineInput input) noexcept {
  return invoke(engine, [&](InkEngineOpaque* value) {
    return value->engine.begin(makeInput(InkStrokeEventType::Down, input), value->frame);
  });
}

int32_t ink_engine_update(InkEngineRef engine, InkEngineInput input) noexcept {
  return ink_engine_mutate_batch(
      engine, INK_ENGINE_BATCH_OPERATION_UPDATE, &input, 1u);
}

int32_t ink_engine_end(InkEngineRef engine, InkEngineInput input) noexcept {
  return ink_engine_mutate_batch(
      engine, INK_ENGINE_BATCH_OPERATION_END, &input, 1u);
}

int32_t ink_engine_mutate_batch(
    InkEngineRef engine, uint32_t operation,
    const InkEngineInput* inputs, size_t input_count) noexcept {
  if (engine == nullptr || inputs == nullptr || input_count == 0 ||
      input_count > kMaxRealInputBatch ||
      (operation != INK_ENGINE_BATCH_OPERATION_UPDATE &&
       operation != INK_ENGINE_BATCH_OPERATION_END)) {
    return InkEngineStatusInvalidInput;
  }
  return invoke(engine, [&](InkEngineOpaque* value) {
    std::array<InkStrokeInput, kMaxRealInputBatch> converted;
    for (size_t index = 0; index < input_count; ++index) {
      const InkStrokeEventType type = operation == INK_ENGINE_BATCH_OPERATION_END &&
              index + 1 == input_count
          ? InkStrokeEventType::Up
          : InkStrokeEventType::Move;
      converted[index] = makeInput(type, inputs[index]);
    }
    const std::span<const InkStrokeInput> batch(converted.data(), input_count);
    return operation == INK_ENGINE_BATCH_OPERATION_END
        ? value->engine.endBatch(batch, value->frame)
        : value->engine.updateBatch(batch, value->frame);
  });
}

int32_t ink_engine_replace_predicted_inputs(
    InkEngineRef engine, const InkEngineInput* inputs, size_t input_count,
    double current_time) noexcept {
  if (engine == nullptr) return InkEngineStatusInvalidInput;
  if ((input_count != 0 && inputs == nullptr) ||
      input_count > kMaxPredictedInputBatch) {
    engine->frame = {};
    engine->segments.clear();
    engine->contours.clear();
    clearView(engine->view);
    return InkEngineStatusInvalidInput;
  }
  try {
    std::array<InkStrokeInput, kMaxPredictedInputBatch> predictedInputs;
    for (size_t index = 0; index < input_count; ++index)
      predictedInputs[index] = makeInput(InkStrokeEventType::Move, inputs[index]);
    InkStrokePredictionFrame prediction;
    const auto status = engine->engine.replacePredictedInputs(
        std::span<const InkStrokeInput>(predictedInputs.data(), input_count),
        current_time, prediction);
    installPredictionFrame(engine, std::move(prediction));
    return static_cast<int32_t>(status.code);
  } catch (...) {
    engine->frame = {};
    engine->segments.clear();
    engine->contours.clear();
    clearView(engine->view);
    return InkEngineStatusException;
  }
}

void ink_engine_cancel(InkEngineRef engine) noexcept {
  if (engine == nullptr) return;
  try {
    engine->engine.cancel();
    engine->frame = {};
    engine->segments.clear();
    engine->contours.clear();
    clearView(engine->view);
  } catch (...) {
    clearView(engine->view);
  }
}

const InkEngineFrameView* ink_engine_frame(InkEngineRef engine) noexcept {
  return engine == nullptr ? nullptr : &engine->view;
}

}  // extern "C"
