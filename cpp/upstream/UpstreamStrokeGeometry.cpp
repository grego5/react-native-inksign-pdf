#include "upstream/UpstreamStrokeGeometry.hpp"

#include <cmath>
#include <stdexcept>
#include <utility>

#include "core/PerfettoTrace.hpp"

namespace margelo::nitro::inksignpdf {

void UpstreamStrokeGeometry::start(float display_brush_epsilon,
                                   float page_to_view_scale) {
  if (!std::isfinite(display_brush_epsilon) || display_brush_epsilon <= 0.0f ||
      !std::isfinite(page_to_view_scale) || page_to_view_scale <= 0.0f) {
    throw std::invalid_argument(
        "display brush epsilon and page-to-view scale must be finite and positive");
  }

  brush_epsilon_page_ = display_brush_epsilon / page_to_view_scale;
  if (!std::isfinite(brush_epsilon_page_) || brush_epsilon_page_ <= 0.0f) {
    throw std::invalid_argument("page-space brush epsilon is not finite");
  }

  extruder_.StartStroke(brush_epsilon_page_, /*is_particle_brush=*/false,
                        mesh_);
  started_ = true;
}

UpstreamStrokeGeometry::StrokeShapeUpdate UpstreamStrokeGeometry::extend(
    absl::Span<const BrushTipState> new_fixed_states,
    absl::Span<const BrushTipState> volatile_states) {
  if (!started_) {
    throw std::logic_error("start() must be called before extend()");
  }
  detail::ScopedPerfettoTrace trace(
      "InkSign/C++ upstream extrusion/simplification");
  return extruder_.ExtendStroke(new_fixed_states, volatile_states);
}

void UpstreamStrokeGeometry::reset() {
  extruder_.RestartStroke();
}

absl::Span<const ink::strokes_internal::StrokeOutline>
UpstreamStrokeGeometry::outlines() const {
  return extruder_.GetOutlines();
}

UpstreamStrokeGeometry::Snapshot UpstreamStrokeGeometry::snapshot() const {
  Snapshot result{.mesh = mesh_.Clone(), .bounds = bounds(), .outlines = {}};
  const auto borrowed_outlines = outlines();
  result.outlines.reserve(borrowed_outlines.size());
  for (const auto& outline : borrowed_outlines) {
    const auto indices = outline.GetIndices();
    result.outlines.push_back({
        .indices = std::vector<std::uint32_t>(indices.begin(), indices.end()),
        .counts = outline.GetIndexCounts(),
    });
  }
  return result;
}

}  // namespace margelo::nitro::inksignpdf
