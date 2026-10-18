#pragma once

#include "primitives/Vec2.hpp"

#include <cstddef>
#include <vector>

namespace margelo::nitro::inksignpdf {

// Native transport for an owned upstream outline. Each mesh edge is encoded
// as a cubic with collinear controls so consumers can share one detached path
// representation without depending on the geometry implementation.
struct CubicSegment {
  Vec2 p0;
  Vec2 c1;
  Vec2 c2;
  Vec2 p3;
  std::size_t sourceStart = 0;
  std::size_t sourceEnd = 0;
};

struct CubicPath {
  std::vector<CubicSegment> segments;
  bool closed = false;
};

struct StrokeContour {
  CubicPath path;
  std::size_t sourceStart = 0;
  std::size_t sourceEnd = 0;
};

using StrokeContourCollection = std::vector<StrokeContour>;

}  // namespace margelo::nitro::inksignpdf
