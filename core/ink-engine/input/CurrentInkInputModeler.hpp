// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include "primitives/StrokePrimitives.hpp"

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace margelo::nitro::inksignpdf::detail {

struct CurrentInkRawInput {
  Vec2 position;
  double elapsedTime = 0.0;
  std::size_t rawSourceIndex = 0;
  double pressure = -1.0;
  double tilt = -1.0;
  double orientation = -1.0;
};

struct CurrentInkModeledInput {
  CenterlineState state;
  std::size_t rawSourceIndex = 0;
  std::size_t modeledSourceIndex = 0;
  bool predicted = false;
};

struct CurrentInkModelState {
  std::size_t stableInputCount = 0;
  std::size_t realInputCount = 0;
  double completeElapsedTime = 0.0;
};

// Adapted from Google Ink's sliding-window input model, keeping the
// stable/unstable ownership contract while using this repository's page-space
// and seconds types. The production owner stores raw real input permanently.
// Prediction uses a reusable owner-local workspace; `smoothing` maps to a
// 0-25 ms averaging window, and zero retains the exact raw positions.
class CurrentInkInputModeler {
 public:
  explicit CurrentInkInputModeler(double smoothing = 0.0);

  void start();
  void extend(std::span<const CurrentInkRawInput> realInputs,
              double currentElapsedTime,
              bool finish);
  void predictionSuffix(std::span<const CurrentInkRawInput> predictedInputs,
                        double currentElapsedTime,
                        std::vector<CurrentInkModeledInput>& output,
                        CurrentInkInputModeler& workspace) const;
  void cancel();

  const CurrentInkModelState& state() const noexcept { return state_; }
  std::size_t realInputCount() const noexcept { return realInputs_.size(); }
  const std::vector<CurrentInkModeledInput>& modeledInputs() const noexcept {
    return modeledInputs_;
  }
  std::uint64_t modeledSamplesEvaluated() const noexcept {
    return modeledSamplesEvaluated_;
  }
  std::uint64_t rebuildCount() const noexcept { return rebuildCount_; }
  std::uint64_t scratchBufferGrowth() const noexcept {
    return scratchBufferGrowth_;
  }
  Vec2 lastRealMovingVelocity() const noexcept {
    return lastRealMovingVelocity_;
  }

 private:
  struct ModeledSample {
    Vec2 position;
    double time = 0.0;
    double pressure = -1.0;
    double tilt = -1.0;
    double orientation = -1.0;
    std::size_t rawSourceIndex = 0;
  };

  void rebuild(std::span<const CurrentInkRawInput> predictedInputs,
               bool finish);
  void modelRealInputs(std::span<const CurrentInkRawInput> inputs,
                       std::vector<ModeledSample>& samples) const;
  void appendPredictedInputs(std::span<const CurrentInkRawInput> predictedInputs,
                             std::vector<ModeledSample>& samples) const;
  void appendModeledSample(std::vector<ModeledSample>& samples,
                           ModeledSample sample, bool forceEndpoint) const;
  ModeledSample modelAt(std::span<const CurrentInkRawInput> inputs,
                        double elapsedTime, std::size_t& startIndex,
                        std::size_t& endIndex) const;
  void computeDerivative(std::vector<CurrentInkModeledInput>& inputs,
                         Vec2 CenterlineState::*valueField,
                         Vec2 CenterlineState::*derivativeField,
                         std::size_t startIndex, std::size_t endIndex) const;
  static ModeledSample interpolate(const CurrentInkRawInput& first,
                                   const CurrentInkRawInput& second,
                                   double elapsedTime);
  static double interpolateValue(double first, double second, double amount);
  static bool hasValue(double value) noexcept;
  static bool withinEpsilon(Vec2 first, Vec2 second) noexcept;
  template <typename Value>
  void reserveScratch(std::vector<Value>& scratch, std::size_t required) const;

  CurrentInkModelState state_;
  double smoothing_ = 0.0;
  double halfWindowSeconds_ = 0.0;
  static constexpr double kMaxWindowSeconds = 0.025;
  static constexpr double kUpsamplingPeriodSeconds = 1.0 / 180.0;
  static constexpr double kPositionEpsilon = 0.01;
  static constexpr std::size_t kMaxUpsampleDivisions = 100;
  Vec2 lastRealMovingVelocity_;
  std::vector<CurrentInkRawInput> realInputs_;
  std::vector<CurrentInkModeledInput> modeledInputs_;
  mutable std::vector<CurrentInkRawInput> inputScratch_;
  mutable std::vector<CurrentInkRawInput> predictionInputScratch_;
  mutable std::vector<ModeledSample> modeledSampleScratch_;
  mutable std::uint64_t modeledSamplesEvaluated_ = 0;
  mutable std::uint64_t scratchBufferGrowth_ = 0;
  std::uint64_t rebuildCount_ = 0;
};

}  // namespace margelo::nitro::inksignpdf::detail
