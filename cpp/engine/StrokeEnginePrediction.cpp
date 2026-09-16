#include "engine/StrokeEngineInternal.hpp"

#include <chrono>
#include <optional>
#include <span>

#include "core/PerfettoTrace.hpp"

namespace margelo::nitro::inksignpdf {
namespace {

using SteadyClock = std::chrono::steady_clock;

std::uint64_t elapsedNanos(SteadyClock::time_point start) {
  return static_cast<std::uint64_t>(std::chrono::duration_cast<
      std::chrono::nanoseconds>(SteadyClock::now() - start).count());
}

void setDirectionalLead(StrokePredictionDiagnostics& diagnostics,
                        Vec2 direction, Vec2 point, double time,
                        double& temporalLead, double& longitudinalLead,
                        double& lateralError) {
  if ((diagnostics.validityFlags & StrokeDiagnosticLatestRealRaw) == 0) return;
  const Vec2 delta = detail::subtract(point, diagnostics.latestRealRawInput);
  temporalLead = time - diagnostics.latestRealRawTime;
  longitudinalLead = detail::dot(delta, direction);
  lateralError = std::abs(delta.x * direction.y - delta.y * direction.x);
}

void populatePlatformPredictionDiagnostics(
    StrokePredictionDiagnostics& diagnostics,
    std::span<const StrokeInput> predictedInputs,
    std::size_t acceptedInputCount, double currentTime,
    std::optional<Vec2> direction) {
  diagnostics.queuedPredictedInputCount = predictedInputs.size();
  diagnostics.processedPredictedInputCount = acceptedInputCount;
  if (acceptedInputCount == 0) return;
  const StrokeInput& latest = predictedInputs[acceptedInputCount - 1];
  diagnostics.validityFlags |= StrokeDiagnosticLatestPlatformPredictedRaw;
  diagnostics.latestPlatformPredictedRawInput = latest.position;
  diagnostics.latestPlatformPredictedRawTime = latest.time;
  diagnostics.inputAgeAtReplacement = currentTime - diagnostics.latestRealRawTime;
  if (direction) setDirectionalLead(
      diagnostics, *direction, latest.position, latest.time,
      diagnostics.platformPredictionTemporalLead,
      diagnostics.platformPredictionLongitudinalLead,
      diagnostics.platformPredictionLateralError);
}

void populatePredictionGeometryDiagnostics(
    const std::vector<detail::CenterlineState>& predictedSuffix,
    const StrokePredictionFrame& output,
    StrokePredictionDiagnostics& diagnostics, std::optional<Vec2> direction) {
  if (!predictedSuffix.empty()) {
    const auto& endpoint = predictedSuffix.back();
    diagnostics.validityFlags |= StrokeDiagnosticPredictedModeledEndpoint;
    diagnostics.predictedModeledEndpoint = endpoint.position;
    diagnostics.predictedModeledTime = endpoint.time;
    if (direction) setDirectionalLead(
        diagnostics, *direction, endpoint.position, endpoint.time,
        diagnostics.modeledPredictionTemporalLead,
        diagnostics.modeledPredictionLongitudinalLead,
        diagnostics.modeledPredictionLateralError);
  }
  if (output.contours.empty() || output.contours.back().path.segments.empty()) return;
  diagnostics.validityFlags |= StrokeDiagnosticTerminalCrossSection;
  diagnostics.terminalLeftEndpoint = output.contours.back().path.segments.back().p3;
  diagnostics.terminalRightEndpoint = diagnostics.terminalLeftEndpoint;
}


}
StrokeStatus StrokeEngine::Impl::replacePredictedInputs(
    std::span<const StrokeInput> predictedInputs, double currentTime,
    StrokePredictionFrame& output) {
  output.clear();
  if (!contact.active()) {
    output.diagnostics.suppressionReason = PredictionSuppressionReason::Inactive;
    return {StrokeStatusCode::NotInProgress, "Prediction requires an active stroke."};
  }
  std::size_t acceptedInputCount = 0;
  const auto modelStart = SteadyClock::now();
  const auto status = centerline.replacePredictedInputs(
      predictedInputs, currentTime, centerlineUpdate, &acceptedInputCount);
  modelDurationNanos = elapsedNanos(modelStart);
  output.diagnostics = diagnosticsSnapshot(
      centerlineUpdate.predictedSuffix.size());
  if (!centerlineUpdate.predictedSuffix.empty()) {
    output.diagnostics.predictedMovingSpeed = detail::length(
        centerlineUpdate.predictedSuffix.back().velocity);
    output.diagnostics.predictedNormalizedSpeed = brush.style().normalizedSpeed(
        output.diagnostics.predictedMovingSpeed);
  }
  const auto direction = detail::engine::recentRealDirection(centerline.points());
  populatePlatformPredictionDiagnostics(output.diagnostics, predictedInputs,
                                        acceptedInputCount, currentTime, direction);
  if (!status.ok()) {
    upstream.extend({}, {});
    detail::perfettoCounter("InkSign C++ emitted upstream states", 0);
    detail::perfettoCounter("InkSign C++ contour count", 0);
    detail::perfettoCounter("InkSign C++ segment count", 0);
    output.diagnostics.suppressionReason = PredictionSuppressionReason::InvalidResult;
    return detail::engine::fromInputStatus(status);
  }
  if (predictedInputs.empty()) {
    upstream.extend({}, {});
    detail::perfettoCounter("InkSign C++ emitted upstream states", 0);
    detail::perfettoCounter("InkSign C++ contour count", 0);
    detail::perfettoCounter("InkSign C++ segment count", 0);
    output.diagnostics.suppressionReason = PredictionSuppressionReason::EmptyBatch;
    return StrokeStatus::success();
  }
  if (centerlineUpdate.predictedSuffix.empty() || brush.modeledPoints().empty()) {
    upstream.extend({}, {});
    detail::perfettoCounter("InkSign C++ emitted upstream states", 0);
    detail::perfettoCounter("InkSign C++ contour count", 0);
    detail::perfettoCounter("InkSign C++ segment count", 0);
    output.diagnostics.suppressionReason = PredictionSuppressionReason::ModelNoUnstableOutput;
    return StrokeStatus::success();
  }
  const auto geometryStart = SteadyClock::now();
  const auto tips = [&] {
    detail::ScopedPerfettoTrace trace("InkSign/C++ brush-tip generation");
    return brush.predict(centerlineUpdate.predictedSuffix,
                         diagnosticsEnabled ? &diagnosticSamples : nullptr);
  }();
  detail::perfettoCounter(
      "InkSign C++ emitted upstream states",
      tips.newFixedUpstreamStates.size() + tips.volatileUpstreamStates.size());
  upstream.extend(tips.newFixedUpstreamStates,
                  tips.volatileUpstreamStates);
  // Use the same upstream-to-transport extraction as committed/final frames.
  {
    detail::ScopedPerfettoTrace trace("InkSign/C++ contour publication");
    output.contours = extractUpstreamContours(
        upstream, brush.modeledPoints().size() + centerlineUpdate.predictedSuffix.size());
  }
  detail::perfettoCounter("InkSign C++ contour count", output.contours.size());
  std::size_t segmentCount = 0;
  for (const auto& contour : output.contours)
    segmentCount += contour.path.segments.size();
  detail::perfettoCounter("InkSign C++ segment count", segmentCount);
  geometryDurationNanos = elapsedNanos(geometryStart);
  output.diagnostics = diagnosticsSnapshot(
      centerlineUpdate.predictedSuffix.size());
  populatePlatformPredictionDiagnostics(output.diagnostics, predictedInputs,
                                        acceptedInputCount, currentTime, direction);
  output.diagnostics.suppressionReason = output.contours.empty()
      ? PredictionSuppressionReason::GeometryEmpty
      : PredictionSuppressionReason::None;
  populatePredictionGeometryDiagnostics(centerlineUpdate.predictedSuffix,
                                        output, output.diagnostics, direction);
  return StrokeStatus::success();
}

}  // namespace margelo::nitro::inksignpdf
