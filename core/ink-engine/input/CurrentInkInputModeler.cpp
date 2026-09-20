// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0

#include "input/CurrentInkInputModeler.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace margelo::nitro::inksignpdf::detail {
namespace {

constexpr std::size_t kModeledSourceStride = 101;

std::size_t modeledSourceIdentity(std::size_t rawSourceIndex,
                                  std::size_t occurrence) {
  return rawSourceIndex * kModeledSourceStride + occurrence;
}

}  // namespace

CurrentInkInputModeler::CurrentInkInputModeler(double smoothing)
    : smoothing_(std::clamp(smoothing, 0.0, 1.0)) {
  halfWindowSeconds_ = smoothing_ * kMaxWindowSeconds * 0.5;
  realInputs_.reserve(256);
  modeledInputs_.reserve(256);
  inputScratch_.reserve(256);
  predictionInputScratch_.reserve(320);
  modeledSampleScratch_.reserve(512);
}

void CurrentInkInputModeler::start() {
  state_ = {};
  lastRealMovingVelocity_ = {};
  realInputs_.clear();
  modeledInputs_.clear();
  modeledSamplesEvaluated_ = 0;
  rebuildCount_ = 0;
  scratchBufferGrowth_ = 0;
}

void CurrentInkInputModeler::cancel() { start(); }

void CurrentInkInputModeler::extend(
    std::span<const CurrentInkRawInput> realInputs, double currentElapsedTime,
    bool finish) {
  if (!realInputs.empty())
    realInputs_.insert(realInputs_.end(), realInputs.begin(), realInputs.end());

  const std::size_t oldStableCount = state_.stableInputCount;
  rebuild({}, finish);
  if (!realInputs_.empty()) {
    const double lastRealTime = realInputs_.back().elapsedTime;
    // Position smoothing consumes one half-window of future raw input. The
    // centered velocity derivative consumes a second, and acceleration a
    // third. Do not freeze a modeled state until all three dependencies are
    // authoritative; otherwise admission batch boundaries change its final
    // acceleration.
    const double stableHorizon = halfWindowSeconds_ * 3.0;
    std::size_t newlyStable = 0;
    while (newlyStable < state_.realInputCount &&
           modeledInputs_[newlyStable].state.time + stableHorizon <
               lastRealTime) {
      ++newlyStable;
    }
    state_.stableInputCount = finish
        ? state_.realInputCount
        : std::min(state_.realInputCount,
                   std::max(oldStableCount, newlyStable));
  } else {
    // Prediction replacement rebuilds the modeled view but does not advance
    // or invalidate the real stable prefix.
    state_.stableInputCount = oldStableCount;
  }
  state_.completeElapsedTime = std::max(
      currentElapsedTime,
      modeledInputs_.empty() ? 0.0 : modeledInputs_.back().state.time);
}

void CurrentInkInputModeler::predictionSuffix(
    std::span<const CurrentInkRawInput> predictedInputs,
    double currentElapsedTime,
    std::vector<CurrentInkModeledInput>& output,
    CurrentInkInputModeler& workspace) const {
  output.clear();
  workspace.start();
  if (realInputs_.empty()) return;

  // A centered prediction sample can only observe real input inside one
  // half-window before the latest real contact. Keep one earlier raw point so
  // interpolation across the window boundary remains exact.
  const double contextStart =
      realInputs_.back().elapsedTime - halfWindowSeconds_;
  auto first = std::lower_bound(
      realInputs_.begin(), realInputs_.end(), contextStart,
      [](const CurrentInkRawInput& input, double time) {
        return input.elapsedTime < time;
      });
  if (first != realInputs_.begin()) --first;
  workspace.realInputs_.assign(first, realInputs_.end());
  workspace.rebuild(predictedInputs, false);
  workspace.state_.completeElapsedTime = std::max(
      currentElapsedTime,
      workspace.modeledInputs_.empty()
          ? 0.0
          : workspace.modeledInputs_.back().state.time);
  const std::size_t start = workspace.state_.realInputCount;
  output.reserve(workspace.modeledInputs_.size() - start);
  output.insert(output.end(),
                workspace.modeledInputs_.begin() +
                    static_cast<std::ptrdiff_t>(start),
                workspace.modeledInputs_.end());
}

bool CurrentInkInputModeler::hasValue(double value) noexcept {
  return value >= 0.0 && std::isfinite(value);
}

double CurrentInkInputModeler::interpolateValue(double first, double second,
                                                double amount) {
  return first + (second - first) * amount;
}

CurrentInkInputModeler::ModeledSample CurrentInkInputModeler::interpolate(
    const CurrentInkRawInput& first, const CurrentInkRawInput& second,
    double elapsedTime) {
  const double duration = second.elapsedTime - first.elapsedTime;
  const double amount = duration > 0.0
      ? std::clamp((elapsedTime - first.elapsedTime) / duration, 0.0, 1.0)
      : 0.0;
  ModeledSample result{
      .position = lerp(first.position, second.position, amount),
      .time = elapsedTime,
      .pressure = -1.0,
      .tilt = -1.0,
      .orientation = -1.0,
      .rawSourceIndex = second.rawSourceIndex};
  if (hasValue(first.pressure) && hasValue(second.pressure))
    result.pressure = interpolateValue(first.pressure, second.pressure, amount);
  if (hasValue(first.tilt) && hasValue(second.tilt))
    result.tilt = interpolateValue(first.tilt, second.tilt, amount);
  if (hasValue(first.orientation) && hasValue(second.orientation))
    result.orientation = interpolateValue(first.orientation, second.orientation,
                                           amount);
  return result;
}

bool CurrentInkInputModeler::withinEpsilon(Vec2 first, Vec2 second) noexcept {
  return distance(first, second) <= kPositionEpsilon;
}

CurrentInkInputModeler::ModeledSample CurrentInkInputModeler::modelAt(
    std::span<const CurrentInkRawInput> inputs, double elapsedTime,
    std::size_t& startIndex, std::size_t& endIndex) const {
  const double firstTime = inputs.front().elapsedTime;
  const double lastTime = inputs.back().elapsedTime;
  const double halfWindow = std::min(
      halfWindowSeconds_,
      std::max(0.0, std::min(elapsedTime - firstTime, lastTime - elapsedTime)));
  const double windowStart = std::max(elapsedTime - halfWindow, firstTime);
  const double windowEnd = std::min(elapsedTime + halfWindow, lastTime);

  while (startIndex + 1 < inputs.size() &&
         inputs[startIndex + 1].elapsedTime <= windowStart) {
    ++startIndex;
  }
  while (endIndex + 1 < inputs.size() &&
         inputs[endIndex].elapsedTime <= windowEnd) {
    ++endIndex;
  }

  const double dt = windowEnd - windowStart;
  if (!(dt > 0.0)) {
    std::size_t index = startIndex;
    while (index + 1 < inputs.size() &&
           inputs[index + 1].elapsedTime <= elapsedTime) {
      ++index;
    }
    const CurrentInkRawInput& input = inputs[index];
    return {.position = input.position,
            .time = elapsedTime,
            .pressure = input.pressure,
            .tilt = input.tilt,
            .orientation = input.orientation};
  }

  Vec2 positionIntegral{};
  double pressureIntegral = 0.0;
  double tiltIntegral = 0.0;
  double orientationXIntegral = 0.0;
  double orientationYIntegral = 0.0;
  bool pressureAvailable = true;
  bool tiltAvailable = true;
  bool orientationAvailable = true;
  for (std::size_t index = startIndex; index < endIndex; ++index) {
    const auto& first = inputs[index];
    const auto& second = inputs[index + 1];
    const double segmentStart = std::max(windowStart, first.elapsedTime);
    const double segmentEnd = std::min(windowEnd, second.elapsedTime);
    const double segmentDuration = segmentEnd - segmentStart;
    if (!(segmentDuration > 0.0)) continue;
    const ModeledSample clippedFirst = segmentStart == first.elapsedTime
        ? ModeledSample{.position = first.position,
                        .time = segmentStart,
                        .pressure = first.pressure,
                        .tilt = first.tilt,
                        .orientation = first.orientation}
        : interpolate(first, second, segmentStart);
    const ModeledSample clippedSecond = segmentEnd == second.elapsedTime
        ? ModeledSample{.position = second.position,
                        .time = segmentEnd,
                        .pressure = second.pressure,
                        .tilt = second.tilt,
                        .orientation = second.orientation}
        : interpolate(first, second, segmentEnd);
    positionIntegral = add(
        positionIntegral,
        scale(add(clippedFirst.position, clippedSecond.position),
              segmentDuration * 0.5));
    if (hasValue(clippedFirst.pressure) && hasValue(clippedSecond.pressure)) {
      pressureIntegral +=
          segmentDuration * 0.5 * (clippedFirst.pressure + clippedSecond.pressure);
    } else {
      pressureAvailable = false;
    }
    if (hasValue(clippedFirst.tilt) && hasValue(clippedSecond.tilt)) {
      tiltIntegral +=
          segmentDuration * 0.5 * (clippedFirst.tilt + clippedSecond.tilt);
    } else {
      tiltAvailable = false;
    }
    if (hasValue(clippedFirst.orientation) && hasValue(clippedSecond.orientation)) {
      orientationXIntegral += segmentDuration * 0.5 *
          (std::cos(clippedFirst.orientation) + std::cos(clippedSecond.orientation));
      orientationYIntegral += segmentDuration * 0.5 *
          (std::sin(clippedFirst.orientation) + std::sin(clippedSecond.orientation));
    } else {
      orientationAvailable = false;
    }
  }

  ModeledSample result{
      .position = scale(positionIntegral, 1.0 / dt),
      .time = elapsedTime,
      .pressure = pressureAvailable ? pressureIntegral / dt : -1.0,
      .tilt = tiltAvailable ? tiltIntegral / dt : -1.0,
      .orientation = orientationAvailable &&
              (orientationXIntegral != 0.0 || orientationYIntegral != 0.0)
          ? std::atan2(orientationYIntegral, orientationXIntegral)
          : -1.0};
  return result;
}

void CurrentInkInputModeler::appendModeledSample(
    std::vector<ModeledSample>& samples, ModeledSample sample,
    bool forceEndpoint) const {
  if (!samples.empty() && sample.time == samples.back().time) {
    if (forceEndpoint) samples.back() = sample;
    return;
  }
  if (!samples.empty() && withinEpsilon(samples.back().position, sample.position)) {
    if (!forceEndpoint ||
        (samples.back().position.x == sample.position.x &&
         samples.back().position.y == sample.position.y)) {
      return;
    }
  }
  samples.push_back(sample);
  ++modeledSamplesEvaluated_;
}

void CurrentInkInputModeler::modelRealInputs(
    std::span<const CurrentInkRawInput> sourceInputs,
    std::vector<ModeledSample>& samples) const {
  samples.clear();
  if (sourceInputs.empty()) return;
  inputScratch_.clear();
  reserveScratch(inputScratch_, sourceInputs.size());
  for (const CurrentInkRawInput& input : sourceInputs) {
    if (!inputScratch_.empty() &&
        input.elapsedTime == inputScratch_.back().elapsedTime)
      inputScratch_.back() = input;
    else
      inputScratch_.push_back(input);
  }
  reserveScratch(samples, inputScratch_.size());
  std::size_t startIndex = 0;
  std::size_t endIndex = 0;
  double previousTime = -std::numeric_limits<double>::infinity();
  for (std::size_t index = 0; index < inputScratch_.size(); ++index) {
    const auto& raw = inputScratch_[index];
    if (std::isfinite(previousTime)) {
      const double delta = raw.elapsedTime - previousTime;
      const std::size_t divisions = halfWindowSeconds_ > 0.0
          ? std::min<std::size_t>(
                static_cast<std::size_t>(
                    std::ceil(delta / kUpsamplingPeriodSeconds)),
                kMaxUpsampleDivisions)
          : 1;
      if (divisions > 1) {
        const double period = delta / static_cast<double>(divisions);
        for (std::size_t part = 1; part < divisions; ++part) {
          auto sample = modelAt(inputScratch_, previousTime + period * part,
                                startIndex, endIndex);
          sample.rawSourceIndex = raw.rawSourceIndex;
          appendModeledSample(samples, sample, false);
          samples.back().rawSourceIndex = raw.rawSourceIndex;
        }
      }
    }
    const bool endpoint = index + 1 == inputScratch_.size();
    ModeledSample sample = endpoint
        ? ModeledSample{.position = raw.position,
                        .time = raw.elapsedTime,
                        .pressure = raw.pressure,
                        .tilt = raw.tilt,
                        .orientation = raw.orientation,
                        .rawSourceIndex = raw.rawSourceIndex}
        : modelAt(inputScratch_, raw.elapsedTime, startIndex, endIndex);
    sample.rawSourceIndex = raw.rawSourceIndex;
    appendModeledSample(samples, sample, endpoint);
    previousTime = raw.elapsedTime;
  }
}

void CurrentInkInputModeler::appendPredictedInputs(
    std::span<const CurrentInkRawInput> predictedInputs,
    std::vector<ModeledSample>& samples) const {
  if (predictedInputs.empty() || realInputs_.empty()) return;
  predictionInputScratch_.clear();
  reserveScratch(predictionInputScratch_,
                 realInputs_.size() + predictedInputs.size());
  predictionInputScratch_.insert(predictionInputScratch_.end(),
                                 realInputs_.begin(), realInputs_.end());
  predictionInputScratch_.insert(predictionInputScratch_.end(),
                                 predictedInputs.begin(), predictedInputs.end());
  std::size_t startIndex = 0;
  std::size_t endIndex = 0;
  double previousTime = realInputs_.back().elapsedTime;
  for (std::size_t predictedIndex = 0; predictedIndex < predictedInputs.size();
       ++predictedIndex) {
    const auto& raw = predictedInputs[predictedIndex];
    const double delta = raw.elapsedTime - previousTime;
    const std::size_t divisions = halfWindowSeconds_ > 0.0
        ? std::min<std::size_t>(
              static_cast<std::size_t>(
                  std::ceil(delta / kUpsamplingPeriodSeconds)),
              kMaxUpsampleDivisions)
        : 1;
    if (divisions > 1) {
      const double period = delta / static_cast<double>(divisions);
      for (std::size_t part = 1; part < divisions; ++part) {
        auto sample = modelAt(predictionInputScratch_,
                              previousTime + period * part,
                              startIndex, endIndex);
        sample.rawSourceIndex = raw.rawSourceIndex;
        appendModeledSample(samples, sample, false);
        samples.back().rawSourceIndex = raw.rawSourceIndex;
      }
    }
    auto sample = modelAt(predictionInputScratch_, raw.elapsedTime,
                          startIndex, endIndex);
    sample.rawSourceIndex = raw.rawSourceIndex;
    appendModeledSample(samples, sample, false);
    previousTime = raw.elapsedTime;
  }
}

template <typename Value>
void CurrentInkInputModeler::reserveScratch(
    std::vector<Value>& scratch, std::size_t required) const {
  if (scratch.capacity() >= required) return;
  scratch.reserve(required);
  ++scratchBufferGrowth_;
}

void CurrentInkInputModeler::computeDerivative(
    std::vector<CurrentInkModeledInput>& inputs,
    Vec2 CenterlineState::*valueField,
    Vec2 CenterlineState::*derivativeField, std::size_t startIndex,
    std::size_t endIndex) const {
  endIndex = std::min(endIndex, inputs.size());
  if (inputs.empty() || startIndex >= endIndex) return;
  std::size_t windowStartIndex = startIndex == 0 ? 0 : startIndex - 1;
  std::size_t windowEndIndex = startIndex == 0 ? 0 : startIndex;
  for (std::size_t index = startIndex; index < endIndex; ++index) {
    if (halfWindowSeconds_ == 0.0) {
      inputs[index].state.*derivativeField = {};
      if (index > 0) {
        const auto& previous = inputs[index - 1].state;
        const double dt = inputs[index].state.time - previous.time;
        if (dt > 0.0) {
          inputs[index].state.*derivativeField = scale(
              subtract(inputs[index].state.*valueField,
                       previous.*valueField),
              1.0 / dt);
        }
      }
      continue;
    }
    const double startTime = std::max(
        inputs.front().state.time,
        inputs[index].state.time - halfWindowSeconds_);
    const double endTime = std::min(
        inputs[endIndex - 1].state.time,
        inputs[index].state.time + halfWindowSeconds_);
    const double dt = endTime - startTime;
    if (!(dt > 0.0)) {
      inputs[index].state.*derivativeField = {};
      continue;
    }
    while (windowStartIndex + 1 < endIndex &&
           inputs[windowStartIndex + 1].state.time <= startTime) {
      ++windowStartIndex;
    }
    while (windowEndIndex + 1 < endIndex &&
           inputs[windowEndIndex].state.time <= endTime) {
      ++windowEndIndex;
    }
    auto valueAt = [&](double time, std::size_t lower) {
      if (lower + 1 >= endIndex)
        return inputs[lower].state.*valueField;
      const auto& first = inputs[lower].state;
      const auto& second = inputs[lower + 1].state;
      const double duration = second.time - first.time;
      if (!(duration > 0.0)) return first.*valueField;
      return lerp(first.*valueField, second.*valueField,
                  std::clamp((time - first.time) / duration, 0.0, 1.0));
    };
    const Vec2 start = valueAt(startTime, windowStartIndex);
    const Vec2 end = valueAt(endTime, windowEndIndex > 0
        ? windowEndIndex - 1 : windowEndIndex);
    inputs[index].state.*derivativeField =
        scale(subtract(end, start), 1.0 / dt);
  }
}

void CurrentInkInputModeler::rebuild(
    std::span<const CurrentInkRawInput> predictedInputs, bool finish) {
  ++rebuildCount_;
  const std::size_t oldStableCount = state_.stableInputCount;
  const Vec2 previousLastRealMovingVelocity = lastRealMovingVelocity_;
  std::size_t rawStart = 0;
  double stableTime = -std::numeric_limits<double>::infinity();
  if (oldStableCount > 0 && oldStableCount <= modeledInputs_.size()) {
    stableTime = modeledInputs_[oldStableCount - 1].state.time;
    const double contextStart = stableTime - halfWindowSeconds_;
    const auto context = std::lower_bound(
        realInputs_.begin(), realInputs_.end(), contextStart,
        [](const CurrentInkRawInput& input, double time) {
          return input.elapsedTime < time;
        });
    rawStart = static_cast<std::size_t>(context - realInputs_.begin());
    if (rawStart > 0) --rawStart;
  }
  modeledSampleScratch_.clear();
  modelRealInputs(
      std::span<const CurrentInkRawInput>(realInputs_).subspan(rawStart),
      modeledSampleScratch_);
  const std::size_t realSampleCount = modeledSampleScratch_.size();
  appendPredictedInputs(predictedInputs, modeledSampleScratch_);

  modeledInputs_.resize(std::min(oldStableCount, modeledInputs_.size()));
  modeledInputs_.reserve(modeledInputs_.size() + modeledSampleScratch_.size());
  std::size_t previousRawSourceIndex = std::numeric_limits<std::size_t>::max();
  std::size_t sourceOccurrence = 0;
  for (std::size_t index = 0; index < modeledSampleScratch_.size(); ++index) {
    const ModeledSample& sample = modeledSampleScratch_[index];
    if (sample.rawSourceIndex == previousRawSourceIndex) {
      ++sourceOccurrence;
    } else {
      previousRawSourceIndex = sample.rawSourceIndex;
      sourceOccurrence = 0;
    }
    const std::size_t modeledSourceIndex = modeledSourceIdentity(
        sample.rawSourceIndex, sourceOccurrence);
    if (sample.time <= stableTime) {
      continue;
    }
    modeledInputs_.push_back({.state = {.position = sample.position,
                                         .velocity = {},
                                         .acceleration = {},
                                         .time = sample.time,
                                         .pressure = sample.pressure,
                                         .tilt = sample.tilt,
                                         .orientation = sample.orientation,
                                         .rawSourceIndex = sample.rawSourceIndex,
                                         .modeledSourceIndex = modeledSourceIndex,
                                         .predicted = index >= realSampleCount},
                              .rawSourceIndex = sample.rawSourceIndex,
                              .modeledSourceIndex = modeledSourceIndex,
                              .predicted = index >= realSampleCount});
  }
  state_.realInputCount = modeledInputs_.size();
  while (state_.realInputCount > oldStableCount &&
         modeledInputs_[state_.realInputCount - 1].predicted) {
    --state_.realInputCount;
  }
  computeDerivative(modeledInputs_, &CenterlineState::position,
                    &CenterlineState::velocity, oldStableCount,
                    state_.realInputCount);
  if (state_.realInputCount < modeledInputs_.size())
    computeDerivative(modeledInputs_, &CenterlineState::position,
                      &CenterlineState::velocity, state_.realInputCount,
                      modeledInputs_.size());
  computeDerivative(modeledInputs_, &CenterlineState::velocity,
                    &CenterlineState::acceleration, oldStableCount,
                    state_.realInputCount);
  if (state_.realInputCount < modeledInputs_.size())
    computeDerivative(modeledInputs_, &CenterlineState::velocity,
                      &CenterlineState::acceleration, state_.realInputCount,
                      modeledInputs_.size());

  lastRealMovingVelocity_ = previousLastRealMovingVelocity;
  for (std::size_t index = oldStableCount;
       index < state_.realInputCount && index < modeledInputs_.size(); ++index) {
    const Vec2 velocity = modeledInputs_[index].state.velocity;
    if (isFinite(velocity) && length(velocity) > 0.0) {
      lastRealMovingVelocity_ = velocity;
    }
  }
  const bool stationaryTerminal = realInputs_.size() > 1 &&
      realInputs_.back().position.x ==
          realInputs_[realInputs_.size() - 2].position.x &&
      realInputs_.back().position.y ==
          realInputs_[realInputs_.size() - 2].position.y;
  if (finish && stationaryTerminal && state_.realInputCount > 1) {
    const std::size_t terminalIndex = state_.realInputCount - 1;
    modeledInputs_[terminalIndex].state.velocity =
        previousLastRealMovingVelocity;
    lastRealMovingVelocity_ = previousLastRealMovingVelocity;
  }

}

}  // namespace margelo::nitro::inksignpdf::detail
