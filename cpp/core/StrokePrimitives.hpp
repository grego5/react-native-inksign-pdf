#pragma once

#include "core/Vec2.hpp"

#include <cstddef>
#include <cmath>

namespace margelo::nitro::inksignpdf::detail {

struct CenterlineState {
  Vec2 position;
  Vec2 velocity;
  Vec2 acceleration;
  double time = 0.0;
  // Stylus state is modeled by the shared Google Ink modeler alongside the
  // position. Keeping it on the authoritative result prevents a second
  // downstream projection/interpolation trajectory.
  double pressure = -1.0;
  double tilt = -1.0;
  double orientation = -1.0;
  // Identity of the accepted raw input that produced this modeled state.
  std::size_t rawSourceIndex = 0;
  // Stable identity of this modeled sample within the authoritative model
  // stream. This is distinct from its current vector position.
  std::size_t modeledSourceIndex = 0;
  bool predicted = false;
};

inline Vec2 add(Vec2 first, Vec2 second) {
  return {first.x + second.x, first.y + second.y};
}

inline Vec2 subtract(Vec2 first, Vec2 second) {
  return {first.x - second.x, first.y - second.y};
}

inline Vec2 scale(Vec2 value, double scalar) {
  return {value.x * scalar, value.y * scalar};
}

inline double dot(Vec2 first, Vec2 second) {
  return first.x * second.x + first.y * second.y;
}

inline double length(Vec2 value) { return std::hypot(value.x, value.y); }

inline double distance(Vec2 first, Vec2 second) {
  return length(subtract(second, first));
}

inline bool isFinite(double value) { return std::isfinite(value); }

inline bool isFinite(Vec2 value) {
  return isFinite(value.x) && isFinite(value.y);
}

inline Vec2 normalize(Vec2 value, Vec2 fallback = {1.0, 0.0}) {
  const double magnitude = length(value);
  return magnitude > 0.0 && isFinite(magnitude)
      ? scale(value, 1.0 / magnitude)
      : fallback;
}

inline double forwardAcceleration(Vec2 velocity, Vec2 acceleration) {
  const double speed = length(velocity);
  if (!(speed > 0.0) || !isFinite(speed) || !isFinite(acceleration)) return 0.0;
  return dot(acceleration, scale(velocity, 1.0 / speed));
}

inline double lateralAcceleration(Vec2 velocity, Vec2 acceleration) {
  const double speed = length(velocity);
  if (!(speed > 0.0) || !isFinite(speed) || !isFinite(acceleration)) return 0.0;
  const Vec2 unitVelocity = scale(velocity, 1.0 / speed);
  return dot(acceleration, {-unitVelocity.y, unitVelocity.x});
}

inline Vec2 lerp(Vec2 first, Vec2 second, double amount) {
  return add(first, scale(subtract(second, first), amount));
}

}  // namespace margelo::nitro::inksignpdf::detail
