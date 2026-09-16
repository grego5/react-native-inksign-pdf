#include "input/CommittedCenterline.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace margelo::nitro::inksignpdf::detail {
namespace {

bool validOptional(double value) {
  return value == -1.0 || (std::isfinite(value) && value >= 0.0);
}

bool validPredictedInput(const StrokeInput& input,
                         const StrokeInput& latestRealInput,
                         double previousTime) {
  return input.eventType == StrokeEventType::Move &&
      isFinite(input.position) && isFinite(input.time) &&
      input.time > previousTime && validOptional(input.pressure) &&
      validOptional(input.tilt) && validOptional(input.orientation) &&
      (input.pressure < 0.0) == (latestRealInput.pressure < 0.0) &&
      (input.tilt < 0.0) == (latestRealInput.tilt < 0.0) &&
      (input.orientation < 0.0) == (latestRealInput.orientation < 0.0);
}

bool sameStylusPresence(const StrokeInput& first,
                        const StrokeInput& second) noexcept {
  return (first.pressure < 0.0) == (second.pressure < 0.0) &&
      (first.tilt < 0.0) == (second.tilt < 0.0) &&
      (first.orientation < 0.0) == (second.orientation < 0.0);
}

CenterlineState absoluteState(const CurrentInkModeledInput& modeled,
                              double strokeStartTime) {
  CenterlineState state = modeled.state;
  state.time += strokeStartTime;
  return state;
}

}  // namespace

CommittedCenterline::CommittedCenterline(CommittedCenterlineConfig config)
    : modeler_(config.smoothing), predictionWorkspace_(config.smoothing) {
  points_.reserve(256);
  normalizedBatchScratch_.reserve(kMaxRealInputBatch);
  rawBatchScratch_.reserve(kMaxRealInputBatch);
  predictedRawScratch_.reserve(kMaxPredictedInputBatch);
  predictedModeledScratch_.reserve(256);
}

InputStatus CommittedCenterline::begin(
    const StrokeInput& input, CommittedCenterlineUpdate& output) {
  return process(input, Operation::Begin, output);
}

InputStatus CommittedCenterline::update(
    const StrokeInput& input, CommittedCenterlineUpdate& output) {
  return updateBatch(std::span<const StrokeInput>(&input, 1), output);
}

InputStatus CommittedCenterline::end(
    const StrokeInput& input, CommittedCenterlineUpdate& output) {
  return endBatch(std::span<const StrokeInput>(&input, 1), output);
}

InputStatus CommittedCenterline::updateBatch(
    std::span<const StrokeInput> inputs, CommittedCenterlineUpdate& output) {
  return processBatch(inputs, Operation::Update, output);
}

InputStatus CommittedCenterline::endBatch(
    std::span<const StrokeInput> inputs, CommittedCenterlineUpdate& output) {
  return processBatch(inputs, Operation::End, output);
}

void CommittedCenterline::cancel() {
  normalizer_.cancel();
  modeler_.cancel();
  points_.clear();
  latestRealInput_.reset();
  lastPublishedStableCount_ = 0;
  strokeStartTime_ = 0.0;
  latestRealInputTime_ = 0.0;
  scratchBufferGrowth_ = 0;
}

InputStatus CommittedCenterline::replacePredictedInputs(
    std::span<const StrokeInput> predictedInputs, double currentTime,
    CommittedCenterlineUpdate& output, std::size_t* acceptedInputCount) {
  output.predictedSuffix.clear();
  if (acceptedInputCount != nullptr) *acceptedInputCount = 0;
  if (!normalizer_.inProgress() || !latestRealInput_.has_value()) {
    return {InputStatusCode::NotInProgress,
            "Prediction requires an active stroke."};
  }
  if (!std::isfinite(currentTime) || currentTime < strokeStartTime_ ||
      currentTime < latestRealInputTime_) {
    return {InputStatusCode::TimeWentBackwards,
            "Prediction time must be in the active stroke clock."};
  }
  if (predictedInputs.size() > kMaxPredictedInputBatch) {
    return {InputStatusCode::InvalidValue,
            "Predicted input batch exceeds the native bound."};
  }

  predictedRawScratch_.clear();
  predictedRawScratch_.reserve(predictedInputs.size());
  double previousTime = latestRealInputTime_;
  for (const StrokeInput& input : predictedInputs) {
    if (!validPredictedInput(input, *latestRealInput_, previousTime)) break;
    const NormalizedInput normalized = {
        .eventType = input.eventType,
        .position = input.position,
        .time = input.time,
        .stylus = {.pressure = input.pressure == -1.0
                       ? std::nullopt
                       : std::optional<double>{input.pressure},
                   .tilt = input.tilt == -1.0
                       ? std::nullopt : std::optional<double>{input.tilt},
                   .orientation = input.orientation == -1.0
                       ? std::nullopt
                       : std::optional<double>{input.orientation}}};
    predictedRawScratch_.push_back(makeRawInput(
        normalized, strokeStartTime_,
        points_.size() + predictedRawScratch_.size()));
    previousTime = input.time;
  }
  // Prediction is evaluated from a bounded copy of the recent real context.
  // The production modeler remains real-only so a preview cannot change stable
  // counts, modeled real fields, or the next real update.
  modeler_.predictionSuffix(predictedRawScratch_,
                            currentTime - strokeStartTime_,
                            predictedModeledScratch_, predictionWorkspace_);
  if (acceptedInputCount != nullptr)
    *acceptedInputCount = predictedRawScratch_.size();
  if (output.predictedSuffix.capacity() < predictedModeledScratch_.size()) {
    output.predictedSuffix.reserve(predictedModeledScratch_.size());
    ++scratchBufferGrowth_;
  }
  for (std::size_t index = 0; index < predictedModeledScratch_.size(); ++index) {
    if (predictedModeledScratch_[index].predicted)
      output.predictedSuffix.push_back(
          absoluteState(predictedModeledScratch_[index], strokeStartTime_));
  }
  return InputStatus::success();
}

CurrentInkRawInput CommittedCenterline::makeRawInput(
    const NormalizedInput& input, double strokeStartTime,
    std::size_t sourceIndex) {
  return {.position = input.position,
          .elapsedTime = input.time - strokeStartTime,
          .rawSourceIndex = sourceIndex,
          .pressure = input.stylus.pressure.value_or(-1.0),
          .tilt = input.stylus.tilt.value_or(-1.0),
          .orientation = input.stylus.orientation.value_or(-1.0)};
}

void CommittedCenterline::fillUpdate(CommittedCenterlineUpdate& output,
                                     const NormalizedInput& acceptedInput) {
  output.acceptedInput = acceptedInput;
  // The complete real range remains owned by the modeler. The current model
  // may have stabilized additional upsampled points, but every point after
  // the old stable prefix remains replaceable until this update has published
  // its revised geometry.
  const auto& modelState = modeler_.state();
  const auto& modeled = modeler_.modeledInputs();
  const std::size_t realEnd = modelState.realInputCount;
  if (realEnd > modeled.size() || lastPublishedStableCount_ > realEnd ||
      modelState.stableInputCount > realEnd) {
    throw std::logic_error("Google Ink model returned invalid real frontiers");
  }
  output.stableInputStart = lastPublishedStableCount_;
  output.stableInputCount = modelState.stableInputCount;
  output.modeledRealInputs = std::span<const CurrentInkModeledInput>(modeled)
      .first(realEnd);
  output.predictedSuffix.clear();
  lastPublishedStableCount_ = modelState.stableInputCount;
}

InputStatus CommittedCenterline::process(
    const StrokeInput& input, Operation operation,
    CommittedCenterlineUpdate& output) {
  if (operation != Operation::Begin) {
    return processBatch(std::span<const StrokeInput>(&input, 1), operation,
                         output);
  }

  NormalizedInput normalized;
  const InputStatus status = normalizer_.begin(input, normalized);
  if (!status.ok()) return status;
  points_.clear();
  modeler_.start();
  lastPublishedStableCount_ = 0;
  strokeStartTime_ = normalized.time;
  const CurrentInkRawInput raw = makeRawInput(
      normalized, strokeStartTime_, points_.size());
  modeler_.extend(std::span<const CurrentInkRawInput>(&raw, 1), 0.0, false);
  latestRealInput_ = input;
  latestRealInputTime_ = normalized.time;
  points_.push_back(normalized);
  fillUpdate(output, normalized);
  return InputStatus::success();
}

InputStatus CommittedCenterline::processBatch(
    std::span<const StrokeInput> inputs, Operation operation,
    CommittedCenterlineUpdate& output) {
  if (inputs.empty()) {
    return {InputStatusCode::InvalidValue,
            "Real input batch must not be empty."};
  }
  if (inputs.size() > kMaxRealInputBatch) {
    return {InputStatusCode::InvalidValue,
            "Real input batch exceeds the native bound."};
  }
  for (std::size_t index = 0; index < inputs.size(); ++index) {
    const StrokeEventType expected = operation == Operation::End &&
            index + 1 == inputs.size()
        ? StrokeEventType::Up
        : StrokeEventType::Move;
    if (inputs[index].eventType != expected) {
      return {InputStatusCode::InvalidEvent,
              "Real input batch contains an invalid event ordering."};
    }
    if ((index == 0 && latestRealInput_.has_value() &&
         !sameStylusPresence(*latestRealInput_, inputs[index])) ||
        (index > 0 && !sameStylusPresence(inputs[index - 1], inputs[index]))) {
      return {InputStatusCode::InvalidValue,
              "Real input batch changes optional stylus fields."};
    }
  }

  normalizedBatchScratch_.clear();
  const std::size_t normalizedCapacity = normalizedBatchScratch_.capacity();
  const InputStatus normalizationStatus = normalizer_.prepareBatch(
      inputs, operation == Operation::End, normalizedBatchScratch_);
  if (!normalizationStatus.ok()) return normalizationStatus;
  if (normalizedBatchScratch_.capacity() != normalizedCapacity)
    ++scratchBufferGrowth_;

  rawBatchScratch_.clear();
  const std::size_t sourceStart = points_.size();
  for (std::size_t index = 0; index < normalizedBatchScratch_.size(); ++index) {
    rawBatchScratch_.push_back(makeRawInput(normalizedBatchScratch_[index], strokeStartTime_,
                               sourceStart + index));
  }
  points_.reserve(points_.size() + normalizedBatchScratch_.size());
  modeler_.extend(
      std::span<const CurrentInkRawInput>(rawBatchScratch_),
      normalizedBatchScratch_.back().time - strokeStartTime_,
      operation == Operation::End);
  latestRealInput_ = inputs.back();
  latestRealInputTime_ = normalizedBatchScratch_.back().time;
  points_.insert(points_.end(), normalizedBatchScratch_.begin(),
                 normalizedBatchScratch_.end());
  normalizer_.commitBatch(inputs, operation == Operation::End);
  fillUpdate(output, normalizedBatchScratch_.back());
  return InputStatus::success();
}

}  // namespace margelo::nitro::inksignpdf::detail
