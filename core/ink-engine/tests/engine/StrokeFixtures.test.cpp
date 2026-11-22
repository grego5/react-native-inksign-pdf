#include "InkEngine.hpp"
#include "ink-engine/tests/fixtures/StrokeFixtures.hpp"

#include "ink-engine/tests/support/TestSupport.hpp"
#include <cmath>
#include <cstdint>
#include <iostream>

using namespace margelo::nitro::inksignpdf;

namespace {

std::uint64_t mix(std::uint64_t hash, std::int64_t value) {
  hash ^= static_cast<std::uint64_t>(value);
  return hash * 1099511628211ULL;
}

std::uint64_t geometryHash(const InkStrokeFrame& frame) {
  std::uint64_t hash = 1469598103934665603ULL;
  for (const ModeledPoint& point : frame.modeledPoints) {
    hash = mix(hash, std::llround(point.point.x * 1000.0));
    hash = mix(hash, std::llround(point.point.y * 1000.0));
    hash = mix(hash, std::llround(point.radius * 1000.0));
  }
  const auto addPath = [&](const auto& path) {
    for (const auto& segment : path.segments) {
      for (const Vec2 point : {segment.p0, segment.c1, segment.c2, segment.p3}) {
        hash = mix(hash, std::llround(point.x * 1000.0));
        hash = mix(hash, std::llround(point.y * 1000.0));
      }
      hash = mix(hash, static_cast<std::int64_t>(segment.sourceStart));
      hash = mix(hash, static_cast<std::int64_t>(segment.sourceEnd));
    }
  };
  for (const auto& contour : frame.contours) {
    hash = mix(hash, static_cast<std::int64_t>(contour.sourceStart));
    hash = mix(hash, static_cast<std::int64_t>(contour.sourceEnd));
    addPath(contour.path);
  }
  return hash;
}

InkStrokeFrame run(const fixtures::Fixture& fixture) {
  InkStrokeConfig config;
  config.smoothing = 0.0;
  InkEngine engine(config);
  InkStrokeFrame frame;
  for (const InkStrokeInput& input : fixture.inputs) {
    const InkStrokeStatus status = input.eventType == InkStrokeEventType::Down
        ? engine.begin(input, frame)
        : input.eventType == InkStrokeEventType::Move
            ? engine.update(input, frame)
            : engine.end(input, frame);
    CHECK(status.ok());
  }
  CHECK(frame.isFinal());
  return frame;
}

}  // namespace

int main() {
  for (const fixtures::Fixture& fixture : fixtures::all()) {
    const InkStrokeFrame first = run(fixture);
    const InkStrokeFrame second = run(fixture);
    CHECK(geometryHash(first) == geometryHash(second));
    CHECK(!first.modeledPoints.empty());
    CHECK(!first.contours.empty());
    for (const auto& contour : first.contours) {
      CHECK(contour.path.closed);
      CHECK(!contour.path.segments.empty());
      for (const auto& segment : contour.path.segments) {
        CHECK(std::isfinite(segment.p0.x));
        CHECK(std::isfinite(segment.c1.y));
        CHECK(std::isfinite(segment.c2.x));
        CHECK(std::isfinite(segment.p3.y));
      }
    }
    for (const ModeledPoint& point : first.modeledPoints) {
      CHECK(std::isfinite(point.acceleration.x));
      CHECK(std::isfinite(point.acceleration.y));
    }
    std::cout << fixture.name << ": " << first.modeledPoints.size() << ", "
              << first.contours.size() << ", " << geometryHash(first)
              << '\n';
  }

  return 0;
}
