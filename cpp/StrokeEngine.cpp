#include "StrokeEngine.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <span>
#include <stdexcept>

#include "core/PerfettoTrace.hpp"
#include "engine/StrokeEngineInternal.hpp"
#include "input/CommittedCenterline.hpp"
#include "input/InputNormalizer.hpp"
#include "modeling/ContactLifecycle.hpp"
#include "modeling/SignatureStrokeStyle.hpp"

namespace margelo::nitro::inksignpdf {
namespace {

using SteadyClock = std::chrono::steady_clock;

using Operation = detail::engine::Operation;

bool validConfig(const StrokeConfig& config) noexcept {
  return std::isfinite(config.minWidth) && std::isfinite(config.maxWidth) &&
         config.minWidth > 0.0 && config.maxWidth > 0.0 &&
         config.minWidth <= config.maxWidth &&
         std::isfinite(config.smoothing) && config.smoothing >= 0.0 &&
         config.smoothing <= 1.0 &&
         std::isfinite(config.logicalDisplayUnitsPerPageUnit) &&
         config.logicalDisplayUnitsPerPageUnit > 0.0;
}

std::uint64_t elapsedNanos(SteadyClock::time_point start) {
  return static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(SteadyClock::now() -
                                                           start)
          .count());
}

void clearFrame(StrokeFrame& output) {
  output.type = StrokeFrameType::Committed;
  output.revision = 0;
  output.committedPointCount = 0;
  output.diagnostics = {};
  output.modeledPointStart = 0;
  output.modeledPoints.clear();
  output.contours.clear();
}

void prepareFrame(StrokeFrame& output) {
  output.modeledPoints.reserve(256);
  output.contours.reserve(8);
}

}  // namespace

StrokeEngine::StrokeEngine(StrokeConfig config)
    : config_(validateConfig(config)), impl_(std::make_unique<Impl>(config_)) {}

StrokeEngine::~StrokeEngine() = default;
StrokeEngine::StrokeEngine(StrokeEngine&&) noexcept = default;
StrokeEngine& StrokeEngine::operator=(StrokeEngine&&) noexcept = default;

const std::vector<ModeledPoint>& StrokeEngine::modeledPoints() const {
  return impl_->brush.modeledPoints();
}

const std::vector<StrokeDiagnosticSample>& StrokeEngine::diagnosticSamples()
    const noexcept {
  return impl_->diagnosticSamples;
}

void StrokeEngine::enableDiagnostics(bool enabled) {
  if (inProgress())
    throw std::logic_error("diagnostics cannot change during a stroke");
  impl_->diagnosticsEnabled = enabled;
  if (!enabled) impl_->diagnosticSamples.clear();
}

bool StrokeEngine::inProgress() const { return impl_->contact.active(); }

const StrokeWorkStats& StrokeEngine::workStats() const noexcept {
  return impl_->workStats;
}

void StrokeEngine::recordFrameFlatteningCapacityGrowth() noexcept {
  ++impl_->workStats.frameFlatteningCapacityGrowth;
}

StrokeStatus StrokeEngine::setConfig(StrokeConfig config) {
  if (inProgress())
    return {StrokeStatusCode::ReconfigureWhileInProgress,
            "Stroke configuration cannot change while a stroke is active."};
  if (!validConfig(config))
    return {StrokeStatusCode::InvalidInput,
            "stroke configuration contains an invalid value."};
  config_ = validateConfig(config);
  impl_ = std::make_unique<Impl>(config_);
  return StrokeStatus::success();
}

StrokeConfig StrokeEngine::validateConfig(StrokeConfig config) {
  if (!validConfig(config))
    throw std::invalid_argument(
        "stroke configuration contains an invalid value");
  return config;
}

namespace {

template <typename ImplType>
StrokeStatus applyRealInput(ImplType& impl, std::span<const StrokeInput> inputs,
                            Operation operation, bool terminal,
                            StrokeFrame& output,
                            bool activateOnAcceptedMovement) {
  const auto modelStart = SteadyClock::now();
  detail::InputStatus inputStatus =
      operation == Operation::End
          ? impl.centerline.endBatch(inputs, impl.centerlineUpdate)
          : impl.centerline.updateBatch(inputs, impl.centerlineUpdate);
  impl.modelDurationNanos = elapsedNanos(modelStart);
  impl.workStats.modelerScratchBufferGrowth =
      impl.centerline.modelScratchBufferGrowth();
  impl.workStats.centerlineScratchBufferGrowth =
      impl.centerline.scratchBufferGrowth();
  if (!inputStatus.ok()) return detail::engine::fromInputStatus(inputStatus);
  if (activateOnAcceptedMovement && !impl.contact.movementAccepted()) {
    const auto& start = impl.centerline.points().front();
    const bool acceptedMovement = std::any_of(
        impl.centerline.points().begin(), impl.centerline.points().end(),
        [&start](const auto& point) {
          return std::hypot(point.position.x - start.position.x,
                            point.position.y - start.position.y) > 0.0;
        });
    if (!acceptedMovement) {
      clearFrame(output);
      output.diagnostics = impl.diagnosticsSnapshot();
      return StrokeStatus::success();
    }
    impl.contact.acceptMovement(impl.centerlineUpdate.acceptedInput.time);
  }
  const auto geometryStart = SteadyClock::now();
  const detail::SignatureBrushRealInput brushInput{
      .states = impl.centerlineUpdate.modeledRealInputs,
      .replacementStart = impl.centerlineUpdate.stableInputStart,
      .stableCount = impl.centerlineUpdate.stableInputCount,
      .lastMovingSpeed =
          detail::length(impl.centerline.lastRealMovingVelocity()),
      .timeOffset = impl.centerline.strokeStartTime()};
  auto* diagnostics =
      impl.diagnosticsEnabled ? &impl.diagnosticSamples : nullptr;
  const auto tips = [&] {
    detail::ScopedPerfettoTrace trace("InkSign/C++ brush-tip generation");
    return terminal
               ? impl.brush.finish(brushInput, impl.workStats, diagnostics)
               : impl.brush.update(brushInput, impl.workStats, diagnostics);
  }();
  detail::perfettoCounter(
      "InkSign C++ emitted upstream states",
      tips.newFixedUpstreamStates.size() + tips.volatileUpstreamStates.size());
  const std::size_t modeledStart = tips.modeledPointStart;
  impl.upstream.extend(tips.newFixedUpstreamStates,
                       tips.volatileUpstreamStates);
  if (!terminal) {
    impl.publishContours(tips.modeledPoints.size(), modeledStart, output);
    output.modeledPoints.assign(
        tips.modeledPoints.begin() + static_cast<std::ptrdiff_t>(modeledStart),
        tips.modeledPoints.end());
  }
  impl.geometryDurationNanos = elapsedNanos(geometryStart);
  output.diagnostics = impl.diagnosticsSnapshot();
  return StrokeStatus::success();
}

}  // namespace

StrokeStatus StrokeEngine::begin(const StrokeInput& input,
                                 StrokeFrame& output) {
  if (inProgress())
    return {StrokeStatusCode::AlreadyInProgress, "A stroke is already active."};
  impl_->reset();
  impl_->diagnosticSamples.clear();
  terminalDiagnostic_ = {};
  prepareFrame(output);
  const auto modelStart = SteadyClock::now();
  const auto status = impl_->centerline.begin(input, impl_->centerlineUpdate);
  impl_->modelDurationNanos = elapsedNanos(modelStart);
  impl_->workStats.modelerScratchBufferGrowth =
      impl_->centerline.modelScratchBufferGrowth();
  impl_->workStats.centerlineScratchBufferGrowth =
      impl_->centerline.scratchBufferGrowth();
  if (!status.ok()) return detail::engine::fromInputStatus(status);
  impl_->contact.begin(impl_->centerlineUpdate.acceptedInput.time);
  impl_->upstream.start(
      0.01f, static_cast<float>(config_.logicalDisplayUnitsPerPageUnit));
  clearFrame(output);
  output.diagnostics = impl_->diagnosticsSnapshot();
  return StrokeStatus::success();
}

StrokeStatus StrokeEngine::update(const StrokeInput& input,
                                  StrokeFrame& output) {
  return updateBatch(std::span<const StrokeInput>(&input, 1), output);
}

StrokeStatus StrokeEngine::end(const StrokeInput& input, StrokeFrame& output) {
  return endBatch(std::span<const StrokeInput>(&input, 1), output);
}

StrokeStatus StrokeEngine::updateBatch(std::span<const StrokeInput> inputs,
                                       StrokeFrame& output) {
  return applyRealInput(*impl_, inputs, Operation::Update, false, output, true);
}

StrokeStatus StrokeEngine::endBatch(std::span<const StrokeInput> inputs,
                                    StrokeFrame& output) {
  const bool batchHasMovement =
      impl_->contact.movementAccepted() ||
      (!impl_->centerline.points().empty() &&
       std::any_of(inputs.begin(), inputs.end(), [this](const auto& input) {
         const auto& start = impl_->centerline.points().front();
         return std::hypot(input.position.x - start.position.x,
                           input.position.y - start.position.y) > 0.0;
       }));
  if (!batchHasMovement) {
    const auto status =
        impl_->centerline.endBatch(inputs, impl_->centerlineUpdate);
    if (!status.ok()) return detail::engine::fromInputStatus(status);
    const auto& start = impl_->centerline.points().front();
    detail::NormalizedInput tap = start;
    tap.eventType = StrokeEventType::Down;
    tap.time = impl_->centerlineUpdate.acceptedInput.time;
    const double radius = detail::durationSensitiveInitialRadius(
        impl_->contact.end(tap.time), impl_->brush.style().maximumRadius());
    const auto tips = [&] {
      detail::ScopedPerfettoTrace trace("InkSign/C++ brush-tip generation");
      return impl_->brush.finishDot(tap, radius);
    }();
    detail::perfettoCounter("InkSign C++ emitted upstream states",
                            tips.newFixedUpstreamStates.size() +
                                tips.volatileUpstreamStates.size());
    impl_->upstream.extend(tips.newFixedUpstreamStates,
                           tips.volatileUpstreamStates);
    clearFrame(output);
    output.type = StrokeFrameType::Final;
    output.committedPointCount = 1;
    output.modeledPoints = impl_->brush.modeledPoints();
    impl_->publishContours(output.committedPointCount, 0, output);
    output.type = StrokeFrameType::Final;
    output.diagnostics = impl_->diagnosticsSnapshot();
    if (impl_->diagnosticsEnabled)
      terminalDiagnostic_ = {
          .valid = true,
          .lastValidMovingSpeed = 0.0,
          .normalizedTerminalSpeed = 0.0,
          .selectedTaperDistance = impl_->brush.styleSnapshot().taper.distance,
          .remainingArclength = 0.0,
          .taperMultiplier = 1.0,
          .taperedRadius = impl_->brush.modeledPoints().front().radius,
          .exactContact = true};
    impl_->reset();
    return StrokeStatus::success();
  }
  const StrokeStatus status =
      applyRealInput(*impl_, inputs, Operation::End, true, output, true);
  if (!status.ok()) return status;
  const auto finalFrameStart = SteadyClock::now();
  clearFrame(output);
  output.type = StrokeFrameType::Final;
  output.committedPointCount = impl_->brush.modeledPoints().size();
  output.modeledPoints = impl_->brush.modeledPoints();
  impl_->publishContours(output.committedPointCount, 0, output);
  output.type = StrokeFrameType::Final;
  impl_->geometryDurationNanos += elapsedNanos(finalFrameStart);
  output.diagnostics = impl_->diagnosticsSnapshot();
  const auto styleSnapshot = impl_->brush.styleSnapshot();
  const auto& taper = styleSnapshot.taper;
  const double terminalSpeed = styleSnapshot.lastMovingRealSpeed;
  const double remaining = 0.0;
  const double untapered = impl_->brush.modeledPoints().empty()
                               ? 0.0
                               : impl_->brush.modeledPoints().back().radius;
  const double terminalRadius =
      impl_->brush.modeledPoints().empty()
          ? 0.0
          : detail::SignatureStrokeStyle::terminalRadiusAt(
                untapered, remaining, taper.distance, taper.strength,
                styleSnapshot.minimumTerminalRadius);
  if (impl_->diagnosticsEnabled)
    terminalDiagnostic_ = {
        .valid = !impl_->brush.modeledPoints().empty(),
        .lastValidMovingSpeed = terminalSpeed,
        .normalizedTerminalSpeed =
            impl_->brush.style().normalizedSpeed(terminalSpeed),
        .selectedTaperDistance = taper.distance,
        .remainingArclength = remaining,
        .taperMultiplier = untapered > 0.0 ? terminalRadius / untapered : 1.0,
        .taperedRadius = terminalRadius,
        .exactContact = taper.active()};
  impl_->reset();
  return StrokeStatus::success();
}

void StrokeEngine::cancel() { impl_->reset(); }

StrokeStatus StrokeEngine::replacePredictedInputs(
    std::span<const StrokeInput> predictedInputs, double currentTime,
    StrokePredictionFrame& output) {
  return impl_->replacePredictedInputs(predictedInputs, currentTime, output);
}

}  // namespace margelo::nitro::inksignpdf
