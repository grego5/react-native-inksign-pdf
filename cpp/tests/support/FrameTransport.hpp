#pragma once

#include "InkEngine.hpp"
#include "InkEngineC.h"

#include <vector>

namespace margelo::nitro::inksignpdf::detail {

// Owns the flattened arrays behind one borrowed C ABI view. The view remains
// valid until replace(), replaceFinal(), or clear() is called.
class FrameTransport {
 public:
  const InkEngineFrameView& replace(const InkStrokeFrame& frame);
  const InkEngineFrameView& replaceFinal(
      std::uint64_t revision, std::size_t committedPointCount,
      StrokeContourCollection contours);
  void clear() noexcept;

  const InkEngineFrameView& view() const noexcept { return view_; }

 private:
  void replaceFrame(std::uint32_t type, const InkStrokeFrame& frame);
  void flatten(const StrokeContourCollection& contours);
  void refreshView(std::uint32_t type, std::uint64_t revision,
                   std::size_t committedPointCount) noexcept;

  std::vector<InkEngineCubicSegment> segments_;
  std::vector<InkEngineCubicContourRecord> contours_;
  InkEngineFrameView view_{};
};

}  // namespace margelo::nitro::inksignpdf::detail
