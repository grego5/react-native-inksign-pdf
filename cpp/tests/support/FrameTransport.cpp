#include "tests/support/FrameTransport.hpp"

namespace margelo::nitro::inksignpdf::detail {

void FrameTransport::flatten(
    const StrokeContourCollection& contours) {
  segments_.clear();
  contours_.clear();
  for (const auto& contour : contours) {
    const std::size_t start = segments_.size();
    for (const auto& segment : contour.path.segments)
      segments_.push_back({.p0 = {segment.p0.x, segment.p0.y},
                           .c1 = {segment.c1.x, segment.c1.y},
                           .c2 = {segment.c2.x, segment.c2.y},
                           .p3 = {segment.p3.x, segment.p3.y},
                           .sourceStart = segment.sourceStart,
                           .sourceEnd = segment.sourceEnd});
    contours_.push_back({.segmentStart = start,
                         .segmentCount = contour.path.segments.size(),
                         .sourceStart = contour.sourceStart,
                         .sourceEnd = contour.sourceEnd,
                         .closed = contour.path.closed ? 1u : 0u});
  }
}

const NSEStrokeFrameView& FrameTransport::replace(const StrokeFrame& frame) {
  replaceFrame(NSEStrokeFrameTypeCommitted, frame);
  return view_;
}

void FrameTransport::replaceFrame(std::uint32_t type, const StrokeFrame& frame) {
  flatten(frame.contours);
  refreshView(type, frame.revision, frame.committedPointCount);
}

const NSEStrokeFrameView& FrameTransport::replaceFinal(
    std::uint64_t revision, std::size_t committedPointCount,
    StrokeContourCollection contours) {
  flatten(contours);
  refreshView(NSEStrokeFrameTypeFinal, revision, committedPointCount);
  return view_;
}

void FrameTransport::clear() noexcept {
  segments_.clear();
  contours_.clear();
  view_ = {};
}

void FrameTransport::refreshView(
    std::uint32_t type, std::uint64_t revision,
    std::size_t committedPointCount) noexcept {
  view_ = {};
  view_.type = type;
  view_.revision = revision;
  view_.committedPointCount = committedPointCount;
  view_.segments = segments_.empty() ? nullptr : segments_.data();
  view_.segmentCount = segments_.size();
  view_.contours = contours_.empty() ? nullptr : contours_.data();
  view_.contourCount = contours_.size();
}

}  // namespace margelo::nitro::inksignpdf::detail
