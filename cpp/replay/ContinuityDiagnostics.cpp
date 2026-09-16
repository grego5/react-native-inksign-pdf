#include "replay/ContinuityDiagnostics.hpp"

#include <cmath>
#include <iomanip>
#include <sstream>
#include <vector>

namespace margelo::nitro::inksignpdf::replay {
namespace {

double distance(Vec2 first, Vec2 second) {
  return std::hypot(second.x - first.x, second.y - first.y);
}

void retainMaximum(ContinuityMaximum& maximum, double value,
                   std::size_t from, std::size_t to) {
  if (value > maximum.value) maximum = {.value = value, .from = from, .to = to};
}

std::optional<ContinuityFailure> violation(
    const ContinuityMetrics& metrics, std::string metric,
    const ContinuityMaximum& maximum, double bound) {
  if (!(maximum.value > bound)) return std::nullopt;
  return ContinuityFailure{.stage = metrics.stage,
                           .metric = std::move(metric),
                           .from = maximum.from,
                           .to = maximum.to,
                           .value = maximum.value,
                           .bound = bound};
}

}  // namespace

std::string ContinuityFailure::describe() const {
  std::ostringstream output;
  output << std::setprecision(9) << "ContinuityInvariantFailure: stage=" << stage
         << " metric=" << metric << " index=" << from << "->" << to
         << " value=" << value << " bound=" << bound;
  return output.str();
}

ContinuityEvaluation evaluateContinuity(
    std::string stage, std::span<const TimedPosition> points,
    const ContinuityBounds& bounds) {
  ContinuityMetrics metrics{.stage = std::move(stage),
                            .pointCount = points.size()};
  if (points.size() < 2) return {.metrics = std::move(metrics)};

  std::vector<double> distances(points.size(), 0.0);
  std::vector<double> speeds(points.size(), 0.0);
  std::vector<Vec2> velocities(points.size());
  for (std::size_t index = 1; index < points.size(); ++index) {
    const double deltaTime = points[index].time - points[index - 1].time;
    const Vec2 delta{points[index].position.x - points[index - 1].position.x,
                     points[index].position.y - points[index - 1].position.y};
    distances[index] = std::hypot(delta.x, delta.y);
    speeds[index] = deltaTime > 0.0
        ? distances[index] / deltaTime
        : (distances[index] == 0.0 ? 0.0
                                   : std::numeric_limits<double>::infinity());
    if (deltaTime > 0.0)
      velocities[index] = {delta.x / deltaTime, delta.y / deltaTime};
    retainMaximum(metrics.adjacentDistance, distances[index], index - 1, index);
    retainMaximum(metrics.speed, speeds[index], index - 1, index);
  }
  for (std::size_t index = 2; index < points.size(); ++index) {
    const double change = distance(velocities[index - 1], velocities[index]);
    retainMaximum(metrics.velocityChange, change, index - 1, index);
  }

  std::optional<ContinuityFailure> failure;
  if (!failure) failure = violation(metrics, "adjacent_distance",
                                    metrics.adjacentDistance,
                                    bounds.adjacentDistance);
  if (!failure) failure = violation(metrics, "speed", metrics.speed, bounds.speed);
  if (!failure) failure = violation(metrics, "velocity_change",
                                    metrics.velocityChange,
                                    bounds.velocityChange);
  return {.metrics = std::move(metrics), .failure = std::move(failure)};
}

}  // namespace margelo::nitro::inksignpdf::replay
