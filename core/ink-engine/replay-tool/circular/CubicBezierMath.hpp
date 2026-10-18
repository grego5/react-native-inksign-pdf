#pragma once

#include "primitives/StrokeOutline.hpp"

namespace margelo::nitro::inksignpdf::detail {

// Bernstein form keeps the factor of two in the middle derivative term explicit.
inline Vec2 cubicDerivative(const CubicSegment& curve, double t) {
  const double u = 1.0 - t;
  return {3.0 * ((curve.c1.x - curve.p0.x) * u * u +
                 2.0 * (curve.c2.x - curve.c1.x) * u * t +
                 (curve.p3.x - curve.c2.x) * t * t),
          3.0 * ((curve.c1.y - curve.p0.y) * u * u +
                 2.0 * (curve.c2.y - curve.c1.y) * u * t +
                 (curve.p3.y - curve.c2.y) * t * t)};
}

inline Vec2 cubicPoint(const CubicSegment& curve, double t) {
  const double u = 1.0 - t;
  return {curve.p0.x * u * u * u + 3.0 * curve.c1.x * u * u * t +
              3.0 * curve.c2.x * u * t * t + curve.p3.x * t * t * t,
          curve.p0.y * u * u * u + 3.0 * curve.c1.y * u * u * t +
              3.0 * curve.c2.y * u * t * t + curve.p3.y * t * t * t};
}

}  // namespace margelo::nitro::inksignpdf::detail
