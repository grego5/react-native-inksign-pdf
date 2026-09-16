#pragma once

#include "StrokeEngine.hpp"
#include "StrokeEngineC.h"

#include <vector>

namespace margelo::nitro::inksignpdf::detail {

// Owns the flattened arrays behind one borrowed C ABI view. The view remains
// valid until replace(), replaceFinal(), or clear() is called.
class FrameTransport {
 public:
  const NSEStrokeFrameView& replace(const StrokeFrame& frame);
  const NSEStrokeFrameView& replaceFinal(
      std::uint64_t revision, std::size_t committedPointCount,
      StrokeContourCollection contours);
  void clear() noexcept;

  const NSEStrokeFrameView& view() const noexcept { return view_; }

 private:
  void replaceFrame(std::uint32_t type, const StrokeFrame& frame);
  void flatten(const StrokeContourCollection& contours);
  void refreshView(std::uint32_t type, std::uint64_t revision,
                   std::size_t committedPointCount) noexcept;

  std::vector<NSEStrokeCubicSegment> segments_;
  std::vector<NSEStrokeCubicContourRecord> contours_;
  NSEStrokeFrameView view_{};
};

}  // namespace margelo::nitro::inksignpdf::detail
