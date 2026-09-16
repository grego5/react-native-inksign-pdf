#include "engine/StrokeEngineInternal.hpp"

#include "core/PerfettoTrace.hpp"
#include <utility>

namespace margelo::nitro::inksignpdf {

void StrokeEngine::Impl::publishContours(
    std::size_t committedPointCount, std::size_t modeledPointStart,
    StrokeFrame& output) {
  detail::ScopedPerfettoTrace trace("InkSign/C++ contour publication");
  auto contours = extractUpstreamContours(upstream, committedPointCount);
  output.type = StrokeFrameType::Committed;
  output.committedPointCount = committedPointCount;
  output.modeledPointStart = modeledPointStart;
  output.contours = std::move(contours);
  ++revision;
  output.revision = revision;
  detail::perfettoCounter("InkSign C++ contour count", output.contours.size());
  std::size_t segmentCount = 0;
  for (const auto& contour : output.contours)
    segmentCount += contour.path.segments.size();
  detail::perfettoCounter("InkSign C++ segment count", segmentCount);
}


}  // namespace margelo::nitro::inksignpdf
