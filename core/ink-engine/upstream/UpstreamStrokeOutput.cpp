#include "upstream/UpstreamStrokeOutput.hpp"

#include <stdexcept>
#include <utility>

namespace margelo::nitro::inksignpdf {

namespace {

template <typename Mesh, typename Outlines, typename IndicesGetter>
StrokeContourCollection extractContours(const Mesh& mesh,
                                        const Outlines& outlines,
                                        std::size_t sourceEnd,
                                        IndicesGetter getIndices) {
  StrokeContourCollection result;
  result.reserve(outlines.size());
  for (const auto& outline : outlines) {
    const auto& indices = getIndices(outline);
    if (indices.size() < 2) continue;
    StrokeContour contour;
    contour.sourceStart = 0;
    contour.sourceEnd = sourceEnd;
    contour.path.closed = true;
    contour.path.segments.reserve(indices.size());
    for (std::size_t index = 0; index < indices.size(); ++index) {
      const auto firstIndex = indices[index];
      const auto secondIndex = indices[(index + 1) % indices.size()];
      if (firstIndex >= mesh.VertexCount() ||
          secondIndex >= mesh.VertexCount()) {
        throw std::logic_error("upstream outline references an invalid vertex");
      }
      const auto first = mesh.VertexPosition(firstIndex);
      const auto second = mesh.VertexPosition(secondIndex);
      const Vec2 p0{first.x, first.y};
      const Vec2 p3{second.x, second.y};
      const Vec2 delta{(p3.x - p0.x) / 3.0, (p3.y - p0.y) / 3.0};
      contour.path.segments.push_back({
          .p0 = p0,
          .c1 = {p0.x + delta.x, p0.y + delta.y},
          .c2 = {p0.x + 2.0 * delta.x, p0.y + 2.0 * delta.y},
          .p3 = p3,
          .sourceStart = 0,
          .sourceEnd = sourceEnd,
      });
    }
    if (!contour.path.segments.empty()) result.push_back(std::move(contour));
  }
  return result;
}

}  // namespace

StrokeContourCollection extractUpstreamContours(
    const UpstreamStrokeGeometry::Snapshot& snapshot, std::size_t sourceEnd) {
  return extractContours(
      snapshot.mesh, snapshot.outlines, sourceEnd,
      [](const auto& outline) -> decltype(auto) { return (outline.indices); });
}

StrokeContourCollection extractUpstreamContours(
    const UpstreamStrokeGeometry& geometry, std::size_t sourceEnd) {
  // The generated contours own their data, so these borrowed views do not
  // escape this synchronous extraction.
  return extractContours(
      geometry.mesh(), geometry.outlines(), sourceEnd,
      [](const auto& outline) { return outline.GetIndices(); });
}

}  // namespace margelo::nitro::inksignpdf
