#pragma once

#include "InkEngine.hpp"

#include <cstddef>
#include <limits>
#include <optional>
#include <span>
#include <string>

namespace margelo::nitro::inksignpdf::replay {

struct TimedPosition {
  Vec2 position;
  double time = 0.0;
};

struct ContinuityBounds {
  double adjacentDistance = std::numeric_limits<double>::infinity();
  double speed = std::numeric_limits<double>::infinity();
  double velocityChange = std::numeric_limits<double>::infinity();
};

struct ContinuityMaximum {
  double value = 0.0;
  std::size_t from = 0;
  std::size_t to = 0;
};

struct ContinuityMetrics {
  std::string stage;
  std::size_t pointCount = 0;
  ContinuityMaximum adjacentDistance;
  ContinuityMaximum speed;
  ContinuityMaximum velocityChange;
};

struct ContinuityFailure {
  std::string stage;
  std::string metric;
  std::size_t from = 0;
  std::size_t to = 0;
  double value = 0.0;
  double bound = 0.0;

  std::string describe() const;
};

struct ContinuityEvaluation {
  ContinuityMetrics metrics;
  std::optional<ContinuityFailure> failure;
};

ContinuityEvaluation evaluateContinuity(
    std::string stage, std::span<const TimedPosition> points,
    const ContinuityBounds& bounds = {});

}  // namespace margelo::nitro::inksignpdf::replay
