#include "engine/InkEngineInternal.hpp"

#include <cmath>

namespace margelo::nitro::inksignpdf::detail::engine {

detail::CommittedCenterlineConfig centerlineConfig(const InkStrokeConfig& config) {
  return {.smoothing = config.smoothing};
}

InkStrokeStatus fromInputStatus(const detail::InputStatus& status) {
  using InputCode = detail::InputStatusCode;
  switch (status.code) {
    case InputCode::Ok: return InkStrokeStatus::success();
    case InputCode::AlreadyInProgress:
      return {InkStrokeStatusCode::AlreadyInProgress, status.message};
    case InputCode::NotInProgress:
      return {InkStrokeStatusCode::NotInProgress, status.message};
    case InputCode::InvalidEvent:
      return {InkStrokeStatusCode::InvalidEvent, status.message};
    case InputCode::InvalidValue:
      return {InkStrokeStatusCode::InvalidInput, status.message};
    case InputCode::DuplicateInput:
      return {InkStrokeStatusCode::DuplicateInput, status.message};
    case InputCode::TimeWentBackwards:
      return {InkStrokeStatusCode::TimeWentBackwards, status.message};
  }
  return {InkStrokeStatusCode::InvalidInput, status.message};
}

std::optional<Vec2> recentRealDirection(
    const std::vector<detail::NormalizedInput>& points) {
  if (points.size() < 2) return std::nullopt;
  const Vec2 latest = points.back().position;
  for (std::size_t index = points.size() - 1; index > 0; --index) {
    const Vec2 delta = detail::subtract(latest, points[index - 1].position);
    const double magnitude = detail::length(delta);
    if (magnitude > 0.0 && std::isfinite(magnitude))
      return detail::scale(delta, 1.0 / magnitude);
  }
  return std::nullopt;
}

}  // namespace margelo::nitro::inksignpdf::detail::engine

namespace margelo::nitro::inksignpdf {
InkEngine::Impl::Impl(const InkStrokeConfig& config)
    : brush(config), centerline(detail::engine::centerlineConfig(config)) {
}

InkStrokePredictionDiagnostics InkEngine::Impl::diagnosticsSnapshot(
    std::size_t predictedModeledInputCount) const {
  InkStrokePredictionDiagnostics diagnostics;
  const auto& modelState = centerline.modelState();
  const auto& modeled = centerline.modeledInputs();
  diagnostics.queuedRealInputCount = centerline.realInputCount();
  diagnostics.processedRealInputCount = centerline.realInputCount();
  diagnostics.stableModeledInputCount = modelState.stableInputCount;
  diagnostics.realModeledInputCount = modelState.realInputCount;
  diagnostics.fullModeledInputCount = modeled.size() + predictedModeledInputCount;
  diagnostics.realMovingSpeed = detail::length(centerline.lastRealMovingVelocity());
  diagnostics.realNormalizedSpeed = brush.style().normalizedSpeed(diagnostics.realMovingSpeed);
  diagnostics.completeElapsedTime = modelState.completeElapsedTime;
  diagnostics.modelDurationNanos = modelDurationNanos;
  diagnostics.geometryDurationNanos = geometryDurationNanos;
  if (const auto& latest = centerline.latestRealInput()) {
    diagnostics.validityFlags |= InkStrokeDiagnosticLatestRealRaw;
    diagnostics.latestRealRawInput = latest->position;
    diagnostics.latestRealRawTime = latest->time;
    diagnostics.realElapsedTime = latest->time - centerline.strokeStartTime();
    if (detail::engine::recentRealDirection(centerline.points()))
      diagnostics.validityFlags |= InkStrokeDiagnosticDirection;
  }
  if (!modeled.empty())
    diagnostics.fullElapsedTime = modeled.back().state.time + centerline.strokeStartTime();
  if (modelState.stableInputCount > 0 && modelState.stableInputCount <= modeled.size()) {
    const auto& state = modeled[modelState.stableInputCount - 1].state;
    diagnostics.validityFlags |= InkStrokeDiagnosticStableModeledTip;
    diagnostics.stableModeledTip = state.position;
    diagnostics.stableModeledTime = state.time + centerline.strokeStartTime();
  }
  if (modelState.realInputCount > 0 && modelState.realInputCount <= modeled.size()) {
    const auto& state = modeled[modelState.realInputCount - 1].state;
    diagnostics.validityFlags |= InkStrokeDiagnosticRealModeledTip;
    diagnostics.realModeledTip = state.position;
    diagnostics.realModeledTime = state.time + centerline.strokeStartTime();
  }
  return diagnostics;
}

void InkEngine::Impl::reset() {
  centerline.cancel();
  contact.reset();
  brush.reset();
  if (upstream.started()) upstream.reset();
  revision = 0;
  modelDurationNanos = 0;
  geometryDurationNanos = 0;
  workStats = {};
}

}  // namespace margelo::nitro::inksignpdf
