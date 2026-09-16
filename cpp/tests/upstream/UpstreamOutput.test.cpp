#include "tests/support/TestSupport.hpp"
#include "upstream/UpstreamStrokeOutput.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

using namespace margelo::nitro::inksignpdf;

namespace {

UpstreamStrokeGeometry::BrushTipState state(float x, float y, float width) {
  return {
      .position = {x, y},
      .width = width,
      .height = width,
      .corner_rounding = 1.0f,
      .rotation = ink::Angle{},
      .slant = ink::Angle{},
      .pinch = 0.0f,
  };
}

bool same(float first, float second) {
  return std::abs(first - second) <= 1e-5f;
}

}  // namespace

int main() {
  UpstreamStrokeGeometry owner;
  owner.start(0.1f, 1.0f);
  const std::vector<UpstreamStrokeGeometry::BrushTipState> states{
      state(0.0f, 0.0f, 4.0f), state(20.0f, 0.0f, 4.0f),
      state(40.0f, 5.0f, 6.0f), state(60.0f, 0.0f, 2.0f),
  };
  owner.extend({}, states);

  const auto snapshot = owner.snapshot();
  CHECK(snapshot.bounds.AsRect().has_value());
  std::size_t expectedContourCount = 0;
  for (const auto& outline : snapshot.outlines) {
    CHECK(outline.indices.size() == outline.counts.left + outline.counts.right);
    if (outline.indices.size() >= 2) ++expectedContourCount;
  }

  const auto contours = extractUpstreamContours(snapshot, states.size());
  CHECK(contours.size() == expectedContourCount);
  std::size_t outlineIndex = 0;
  for (const auto& outline : snapshot.outlines) {
    if (outline.indices.size() < 2) continue;
    const auto& contour = contours[outlineIndex++];
    CHECK(contour.sourceStart == 0);
    CHECK(contour.sourceEnd == states.size());
    CHECK(contour.path.closed);
    CHECK(contour.path.segments.size() == outline.indices.size());
    for (std::size_t index = 0; index < outline.indices.size(); ++index) {
      const auto first = snapshot.mesh.VertexPosition(outline.indices[index]);
      const auto second = snapshot.mesh.VertexPosition(
          outline.indices[(index + 1) % outline.indices.size()]);
      const auto& segment = contour.path.segments[index];
      CHECK(same(segment.p0.x, first.x));
      CHECK(same(segment.p0.y, first.y));
      CHECK(same(segment.p3.x, second.x));
      CHECK(same(segment.p3.y, second.y));
      CHECK(same(segment.c1.x, segment.p0.x +
                              (segment.p3.x - segment.p0.x) / 3.0f));
      CHECK(same(segment.c1.y, segment.p0.y +
                              (segment.p3.y - segment.p0.y) / 3.0f));
      CHECK(same(segment.c2.x, segment.p0.x +
                              2.0f * (segment.p3.x - segment.p0.x) / 3.0f));
      CHECK(same(segment.c2.y, segment.p0.y +
                              2.0f * (segment.p3.y - segment.p0.y) / 3.0f));
      CHECK(segment.sourceStart == 0);
      CHECK(segment.sourceEnd == states.size());
      const auto& next = contour.path.segments[(index + 1) %
                                               contour.path.segments.size()];
      CHECK(same(segment.p3.x, next.p0.x));
      CHECK(same(segment.p3.y, next.p0.y));
    }
  }

  // The returned data is detached from the live owner and remains valid after
  // the owner is revised for the next frame.
  const auto snapshotVertexData = snapshot.mesh.RawVertexData();
  owner.extend(states, {});
  CHECK(snapshot.mesh.RawVertexData() == snapshotVertexData);
  CHECK(!extractUpstreamContours(owner, states.size()).empty());
  return 0;
}
