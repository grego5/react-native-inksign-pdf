#include "modeling/SignatureBrushTipModeler.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace margelo::nitro::inksignpdf::detail {
namespace {
using UpstreamBrushTipState = ink::strokes_internal::BrushTipState;

UpstreamBrushTipState makeUpstreamState(const StyledTipState& state);

double crossMagnitude(Vec2 first, Vec2 second) {
  return std::abs(first.x * second.y - first.y * second.x);
}

ModeledPoint makeModeledPoint(
    const detail::VelocityWidthPoint& modified,
    const detail::CenterlineState& state, const ModeledPoint* previous,
    double minimum, double maximum, double timeOffset = 0.0) {
  ModeledPoint point;
  point.point = state.position;
  point.time = state.time + timeOffset;
  point.velocity = detail::length(state.velocity);
  point.acceleration = state.acceleration;
  point.pressure = maximum > minimum
      ? std::clamp((modified.radius - minimum) / (maximum - minimum), 0.0,
                   1.0)
      : 1.0;
  point.tilt = modified.input.stylus.tilt.value_or(-1.0);
  point.orientation = modified.input.stylus.orientation.value_or(-1.0);
  point.radius = modified.radius;
  if (previous != nullptr) {
    point.tangent = {point.point.x - previous->point.x,
                     point.point.y - previous->point.y};
    point.distance = std::hypot(point.tangent.x, point.tangent.y);
    point.runningLength = previous->runningLength + point.distance;
  } else {
    point.tangent = state.velocity;
  }
  return point;
}

template <typename T>
void ensureScratchCapacity(std::vector<T>& scratch, std::size_t required,
                           InkStrokeWorkStats* stats) {
  if (scratch.capacity() >= required) return;
  scratch.reserve(required);
  if (stats != nullptr) ++stats->scratchBufferGrowth;
}

void styleStateSuffix(
    std::span<const ModeledPoint> points, std::size_t sourceIndexStart,
    const detail::SignatureStrokeStyle::Snapshot& style,
    std::vector<StyledTipState>& result, InkStrokeWorkStats* stats) {
  result.clear();
  if (points.empty()) return;
  ensureScratchCapacity(result, points.size(), stats);
  double totalArcLength = points.back().runningLength;
  // The common long-stroke case already has the complete length in the
  // monotonic modeled state. For a short stroke, retain the old reverse-sum
  // value because effectiveDistance is clamped to total arclength and the
  // whole stroke is mutable anyway.
  if (sourceIndexStart == 0 && totalArcLength < style.taper.distance) {
    totalArcLength = 0.0;
    for (std::size_t index = points.size(); index-- > 1;)
      totalArcLength += points[index].distance;
  }
  const double effectiveDistance =
      std::min(style.taper.distance, totalArcLength);
  result.resize(points.size());
  double remaining = 0.0;
  for (std::size_t reverse = points.size(); reverse-- > 0;) {
    const std::size_t index = reverse;
    const auto& point = points[index];
    const double radius = style.taper.active()
        ? detail::SignatureStrokeStyle::terminalRadiusAt(
              point.radius, remaining, effectiveDistance,
              style.taper.strength, style.minimumTerminalRadius)
        : point.radius;
    result[index] = {point.point, radius, sourceIndexStart + index};
    if (index > 0) remaining += point.distance;
  }
  if (stats != nullptr) stats->styleStatesProcessed += points.size();
}

UpstreamBrushTipState makeUpstreamState(const StyledTipState& state) {
  const float diameter = static_cast<float>(2.0 * state.radius);
  return {
      .position = {.x = static_cast<float>(state.center.x),
                   .y = static_cast<float>(state.center.y)},
      .width = diameter,
      .height = diameter,
      .corner_rounding = 1.0f,
      .rotation = {},
      .slant = {},
      .pinch = 0.0f,
  };
}

void materializeUpstreamStates(
    std::span<const StyledTipState> styledStates,
    std::vector<UpstreamBrushTipState>& result) {
  result.resize(styledStates.size());
  for (std::size_t index = 0; index < styledStates.size(); ++index)
    result[index] = makeUpstreamState(styledStates[index]);
}

std::size_t taperSafeFixedCount(const std::vector<ModeledPoint>& points,
                                std::size_t stablePrefix,
                                double maximumDistance,
                                InkStrokeWorkStats* stats) {
  const std::size_t immutableCount = std::min(stablePrefix, points.size());
  if (immutableCount == 0) return 0;
  if (stats != nullptr) ++stats->boundarySearches;
  const double boundary = points[immutableCount - 1].runningLength -
      maximumDistance;
  const auto firstMutable = std::lower_bound(
      points.begin(), points.begin() + static_cast<std::ptrdiff_t>(immutableCount),
      boundary,
      [](const ModeledPoint& point, double value) {
        return point.runningLength < value;
      });
  return static_cast<std::size_t>(firstMutable - points.begin());
}

}  // namespace

SignatureBrushTipModeler::SignatureBrushTipModeler(const InkStrokeConfig& config)
    : style_(config.minWidth * 0.5, config.maxWidth * 0.5,
             config.logicalDisplayUnitsPerPageUnit),
      velocityWidth_(style_), widthInitialSnapshot_(velocityWidth_.snapshot()),
      widthCheckpoint_{.index = 0, .snapshot = widthInitialSnapshot_} {
  styledStateScratch_.reserve(256);
  upstreamStateScratch_.reserve(256);
  modeledPoints_.reserve(256);
  predictionPointScratch_.reserve(64);
}

void SignatureBrushTipModeler::reset() {
  velocityWidth_.cancel();
  widthInitialSnapshot_ = velocityWidth_.snapshot();
  widthCheckpoint_ = {.index = 0, .snapshot = widthInitialSnapshot_};
  submittedFixedCount_ = 0;
  lastMovingRealSpeed_ = 0.0;
  modeledPoints_.clear();
  styledStateScratch_.clear();
  upstreamStateScratch_.clear();
  predictionPointScratch_.clear();
}

SignatureBrushTipUpdate SignatureBrushTipModeler::update(
    SignatureBrushRealInput input,
    InkStrokeWorkStats& workStats,
    std::vector<InkStrokeDiagnosticSample>* diagnostics) {
  return processReal(input, false, workStats, diagnostics);
}

SignatureBrushTipUpdate SignatureBrushTipModeler::finish(
    SignatureBrushRealInput input,
    InkStrokeWorkStats& workStats,
    std::vector<InkStrokeDiagnosticSample>* diagnostics) {
  return processReal(input, true, workStats, diagnostics);
}

SignatureBrushTipUpdate SignatureBrushTipModeler::processReal(
    SignatureBrushRealInput input,
    bool terminal, InkStrokeWorkStats& workStats,
    std::vector<InkStrokeDiagnosticSample>* diagnostics) {
  if (std::isfinite(input.lastMovingSpeed) && input.lastMovingSpeed > 0.0)
    lastMovingRealSpeed_ = input.lastMovingSpeed;
  const auto modeledStart = processWidths(input, terminal, workStats, diagnostics);
  auto result = materialize(input.stableCount, workStats, diagnostics);
  result.modeledPointStart = modeledStart;
  return result;
}

SignatureBrushTipUpdate SignatureBrushTipModeler::finishDot(
    const NormalizedInput& input, double radius) {
  const CenterlineState state{.position = input.position, .velocity = {},
                             .acceleration = {}, .time = input.time};
  const auto modified = velocityWidth_.dot(input, radius);
  modeledPoints_.clear();
  modeledPoints_.push_back(makeModeledPoint(
      modified, state, nullptr, style_.minimumRadius(),
      style_.maximumRadius()));
  styledStateScratch_.clear();
  styledStateScratch_.push_back(
      {modeledPoints_.front().point, modeledPoints_.front().radius, 0});
  materializeUpstreamStates(styledStateScratch_, upstreamStateScratch_);
  return splitUpdate(modeledPoints_, 0, 0);
}

SignatureBrushTipUpdate SignatureBrushTipModeler::splitUpdate(
    std::span<const ModeledPoint> points, std::size_t sourceStart,
    std::size_t upstreamSeam) {
  if (sourceStart > upstreamSeam ||
      upstreamSeam - sourceStart > upstreamStateScratch_.size())
    throw std::logic_error("invalid upstream source seam");
  const std::size_t upstreamStart = upstreamSeam - sourceStart;
  const std::size_t upstreamCount =
      std::min(upstreamStart, upstreamStateScratch_.size());
  const auto upstreamStates = std::span<const UpstreamBrushTipState>(
      upstreamStateScratch_);
  return {.modeledPoints = points,
          .newFixedUpstreamStates = upstreamStates.first(upstreamCount),
          .volatileUpstreamStates = upstreamStates.subspan(upstreamCount),
          .modeledPointStart = sourceStart};
}

std::size_t SignatureBrushTipModeler::processWidths(
    SignatureBrushRealInput input,
    bool terminal, InkStrokeWorkStats& workStats,
    std::vector<InkStrokeDiagnosticSample>* diagnostics) {
  const std::size_t modeledStart = input.replacementStart;
  if (modeledStart > modeledPoints_.size())
    throw std::logic_error("modeled replacement start exceeds committed points");
  if (diagnostics != nullptr) {
    diagnostics->erase(
        std::remove_if(diagnostics->begin(),
                       diagnostics->end(),
                       [modeledStart](const auto& sample) {
                         return sample.predicted ||
                             sample.modeledIndex >= modeledStart;
                       }),
        diagnostics->end());
  }
  const bool appendOnly = modeledStart == modeledPoints_.size();
  if (!appendOnly) {
    if (modeledStart != widthCheckpoint_.index)
      throw std::logic_error("width checkpoint does not match model seam");
    modeledPoints_.resize(modeledStart);
    velocityWidth_.restore(modeledStart == 0 ? widthInitialSnapshot_
                                             : widthCheckpoint_.snapshot);
  }
  for (std::size_t index = modeledStart; index < input.states.size(); ++index) {
    const auto& modeledInput = input.states[index];
    const auto& modeled = modeledInput.state;
    const double modeledTime = modeled.time + input.timeOffset;
    const auto event = terminal && index + 1 == input.states.size()
        ? InkStrokeEventType::Up
        : modeledPoints_.empty() ? InkStrokeEventType::Down : InkStrokeEventType::Move;
    const detail::NormalizedInput normalized = {
        .eventType = event, .position = modeled.position, .time = modeledTime,
        .stylus = {
            .pressure = modeled.pressure >= 0.0 ? std::optional<double>{modeled.pressure} : std::nullopt,
            .tilt = modeled.tilt >= 0.0 ? std::optional<double>{modeled.tilt} : std::nullopt,
            .orientation = modeled.orientation >= 0.0 ? std::optional<double>{modeled.orientation} : std::nullopt}};
    const auto modified = event == InkStrokeEventType::Down
        ? velocityWidth_.begin(normalized, modeled.velocity)
        : velocityWidth_.update(normalized, modeled.velocity);
    modeledPoints_.push_back(makeModeledPoint(
        modified, modeled,
        modeledPoints_.empty() ? nullptr : &modeledPoints_.back(),
        style_.minimumRadius(), style_.maximumRadius(), input.timeOffset));
    if (diagnostics != nullptr) {
      const double speed = detail::length(modeled.velocity);
      const double scale = style_.snapshot().logicalDisplayUnitsPerPageUnit;
      const double displaySpeed = speed * scale;
      const double forward = detail::forwardAcceleration(
          modeled.velocity, modeled.acceleration);
      const double velocityLength = detail::length(modeled.velocity);
      const double lateral = velocityLength > 0.0
          ? crossMagnitude(modeled.velocity, modeled.acceleration) / velocityLength
          : 0.0;
      diagnostics->push_back({
          .modeledIndex = index,
          .rawSourceIndex = modeled.rawSourceIndex,
          .modeledSourceIndex = modeled.modeledSourceIndex,
          .time = modeledTime,
          .position = modeled.position,
          .runningLength = modeledPoints_.back().runningLength,
          .velocity = modeled.velocity,
          .displaySpeed = displaySpeed,
          .normalizedSpeed = style_.normalizedSpeed(speed),
          .acceleration = modeled.acceleration,
          .forwardAcceleration = forward,
          .lateralAcceleration = lateral,
          .runningLengthDisplay = modeledPoints_.back().runningLength * scale,
          .forwardAccelerationDisplay = forward * scale,
          .lateralAccelerationDisplay = lateral * scale,
          .dtSeconds = modified.dtSeconds,
          .turnFactor = modified.turnFactor,
          .effectiveSpeedDisplay = modified.effectiveSpeedDisplay,
          .targetRadius = modified.targetRadius,
          .radius = modified.radius,
          .segmentDistance = modified.segmentDistance,
          .responseDistancePage = modified.responseDistancePage,
          .responseAlpha = modified.responseAlpha,
          .finalRadius = modified.radius,
          .stable = index < input.stableCount,
          .real = true,
          .predicted = modeled.predicted});
    }
    ++workStats.widthPointsProcessed;
    if (index + 1 <= input.stableCount) {
      widthCheckpoint_ = {
          .index = index + 1, .snapshot = velocityWidth_.snapshot()};
    }
  }
  return modeledStart;
}

SignatureBrushTipUpdate SignatureBrushTipModeler::materialize(
    std::size_t stableCount, InkStrokeWorkStats& workStats,
    std::vector<InkStrokeDiagnosticSample>* diagnostics) {
  const auto& points = modeledPoints_;
  const auto styleSnapshot = this->styleSnapshot();
  const std::size_t modelStable = std::min(
      stableCount, points.size());
  const std::size_t widthStable =
      std::min(widthCheckpoint_.index, points.size());
  const std::size_t stablePrefix = std::min(modelStable, widthStable);
  // Only arclength inside the immutable prefix is guaranteed to survive the
  // next model replacement. States whose taper safety depends on the mutable
  // suffix remain replaceable until finish.
  const std::size_t fixedCount = taperSafeFixedCount(
      points, stablePrefix, styleSnapshot.maximumTaperDistance, &workStats);
  if (fixedCount < submittedFixedCount_)
    throw std::logic_error("upstream fixed frontier moved backwards");
  const std::size_t suffixStart = submittedFixedCount_;
  const std::size_t suffixCount = points.size() - suffixStart;
  workStats.immutableStatesReused += suffixStart;
  ensureScratchCapacity(styledStateScratch_, suffixCount, &workStats);
  styleStateSuffix(
      std::span<const ModeledPoint>(
          points.data() + static_cast<std::ptrdiff_t>(suffixStart), suffixCount),
      suffixStart, styleSnapshot, styledStateScratch_, &workStats);
  ensureScratchCapacity(upstreamStateScratch_, styledStateScratch_.size(),
                        &workStats);
  materializeUpstreamStates(styledStateScratch_, upstreamStateScratch_);
  if (diagnostics != nullptr) for (auto& sample : *diagnostics) {
    if (!sample.predicted && sample.modeledIndex >= suffixStart &&
        sample.modeledIndex < points.size())
      sample.finalRadius = styledStateScratch_[sample.modeledIndex - suffixStart].radius;
  }
  workStats.tipStatesMaterialized +=
      styledStateScratch_.size();
  if (diagnostics != nullptr) for (auto& diagnostic : *diagnostics) {
    if (!diagnostic.predicted && diagnostic.modeledIndex >= suffixStart &&
        diagnostic.modeledIndex < points.size()) {
      diagnostic.fixedCenterlineFrontier = fixedCount;
      diagnostic.contourSourceStart = suffixStart;
      diagnostic.contourSourceEnd = points.size();
    }
  }
  submittedFixedCount_ = fixedCount;
  return splitUpdate(modeledPoints_, suffixStart, fixedCount);
}

SignatureBrushTipUpdate SignatureBrushTipModeler::predict(
    std::span<const CenterlineState> predicted,
    std::vector<InkStrokeDiagnosticSample>* diagnostics) {
  const auto& realPoints = modeledPoints_;
  if (realPoints.size() < submittedFixedCount_)
    throw std::logic_error("prediction real state range is invalid");
  const std::size_t realStart =
      std::min(submittedFixedCount_, realPoints.size());
  auto& points = predictionPointScratch_;
  ensureScratchCapacity(points, realPoints.size() - realStart + predicted.size(),
                        nullptr);
  points.clear();
  if (diagnostics != nullptr) {
    diagnostics->erase(
        std::remove_if(diagnostics->begin(),
                       diagnostics->end(),
                       [](const auto& sample) { return sample.predicted; }),
        diagnostics->end());
  }
  points.insert(points.end(),
                realPoints.begin() + static_cast<std::ptrdiff_t>(realStart),
                realPoints.end());
  detail::VelocityWidthModel width = velocityWidth_;
  const ModeledPoint* previous = realPoints.empty() ? nullptr : &realPoints.back();
  for (const auto& state : predicted) {
    const detail::NormalizedInput input = {
        .eventType = InkStrokeEventType::Move, .position = state.position,
        .time = state.time,
        .stylus = {
            .pressure = state.pressure >= 0.0 ? std::optional<double>{state.pressure} : std::nullopt,
            .tilt = state.tilt >= 0.0 ? std::optional<double>{state.tilt} : std::nullopt,
            .orientation = state.orientation >= 0.0 ? std::optional<double>{state.orientation} : std::nullopt}};
    const auto modified = width.update(input, state.velocity);
    points.push_back(makeModeledPoint(
        modified, state, previous, style_.minimumRadius(),
        style_.maximumRadius()));
    if (diagnostics != nullptr) {
      const std::size_t predictedIndex =
          points.size() - (realPoints.size() - realStart) - 1;
      const double speed = detail::length(state.velocity);
      const double scale = style_.snapshot().logicalDisplayUnitsPerPageUnit;
      const double forward = detail::forwardAcceleration(
          state.velocity, state.acceleration);
      const double lateral = detail::lateralAcceleration(
          state.velocity, state.acceleration);
      diagnostics->push_back({
          .modeledIndex = realPoints.size() + predictedIndex,
          .rawSourceIndex = state.rawSourceIndex,
          .modeledSourceIndex = state.modeledSourceIndex,
          .time = state.time,
          .position = state.position,
          .runningLength = points.back().runningLength,
          .velocity = state.velocity,
          .displaySpeed = speed * scale,
          .normalizedSpeed = style_.normalizedSpeed(speed),
          .acceleration = state.acceleration,
          .forwardAcceleration = forward,
          .lateralAcceleration = lateral,
          .runningLengthDisplay = points.back().runningLength * scale,
          .forwardAccelerationDisplay = forward * scale,
          .lateralAccelerationDisplay = lateral * scale,
          .dtSeconds = modified.dtSeconds,
          .turnFactor = modified.turnFactor,
          .effectiveSpeedDisplay = modified.effectiveSpeedDisplay,
          .targetRadius = modified.targetRadius,
          .radius = modified.radius,
          .segmentDistance = modified.segmentDistance,
          .responseDistancePage = modified.responseDistancePage,
          .responseAlpha = modified.responseAlpha,
          .finalRadius = modified.radius,
          .stable = false,
          .real = false,
          .predicted = true});
    }
    previous = &points.back();
  }
  const auto styleSnapshot = style_.snapshotForSpeed(lastMovingRealSpeed_)
      .snapshotForSpeed(predicted.empty() ? 0.0 : detail::length(predicted.back().velocity))
      .snapshot();
  styleStateSuffix(points, realStart, styleSnapshot, styledStateScratch_, nullptr);
  materializeUpstreamStates(styledStateScratch_, upstreamStateScratch_);
  if (diagnostics != nullptr) for (auto& sample : *diagnostics) {
    if (sample.predicted)
      sample.finalRadius = styledStateScratch_[sample.modeledIndex - realStart].radius;
  }
  // Prediction is entirely replaceable. The copied real tail must remain in
  // the volatile span so a later real update can replace it; it is not a new
  // upstream fixed frontier.
  return splitUpdate(points, realStart, realStart);
}

}  // namespace margelo::nitro::inksignpdf::detail
