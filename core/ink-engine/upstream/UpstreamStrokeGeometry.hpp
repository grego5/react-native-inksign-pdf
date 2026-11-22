#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "ink/geometry/envelope.h"
#include "ink/geometry/mutable_mesh.h"
#include "ink/strokes/primitives/brush_tip_extruder.h"
#include "ink/strokes/primitives/brush_tip_state.h"
#include "ink/strokes/primitives/stroke_vertex.h"
#include "ink/strokes/primitives/stroke_outline.h"
#include "ink/strokes/primitives/stroke_shape_update.h"

namespace margelo::nitro::inksignpdf {

// Native owner for the upstream BrushTipExtruder. The mesh is owned by this
// object and is declared before the extruder so it outlives all extruder use.
// Views returned by mesh() and outlines() are borrowed and are invalidated by
// the next mutation. snapshot() is the owned boundary for consumers that need
// to retain geometry across a subsequent update.
class UpstreamStrokeGeometry {
 public:
  using BrushTipState = ink::strokes_internal::BrushTipState;
  using StrokeShapeUpdate = ink::strokes_internal::StrokeShapeUpdate;

  struct OutlineSnapshot {
    std::vector<std::uint32_t> indices;
    ink::strokes_internal::StrokeOutline::IndexCounts counts;
  };

  struct Snapshot {
    ink::MutableMesh mesh;
    ink::Envelope bounds;
    std::vector<OutlineSnapshot> outlines;
  };

  UpstreamStrokeGeometry()
      : mesh_(ink::strokes_internal::StrokeVertex::FullMeshFormat()) {}
  UpstreamStrokeGeometry(const UpstreamStrokeGeometry&) = delete;
  UpstreamStrokeGeometry& operator=(const UpstreamStrokeGeometry&) = delete;

  // Converts the display-space epsilon to page units once, then freezes it
  // for this stroke. The page-to-view scale must be finite and positive.
  void start(float display_brush_epsilon, float page_to_view_scale);
  StrokeShapeUpdate extend(
      absl::Span<const BrushTipState> new_fixed_states,
      absl::Span<const BrushTipState> volatile_states);
  void reset();

  const ink::Envelope& bounds() const noexcept { return extruder_.GetBounds(); }
  absl::Span<const ink::strokes_internal::StrokeOutline> outlines() const;
  const ink::MutableMesh& mesh() const noexcept { return mesh_; }
  Snapshot snapshot() const;

  float brushEpsilonPageUnits() const noexcept { return brush_epsilon_page_; }
  bool started() const noexcept { return started_; }

 private:
  // Keep the mesh before the extruder: C++ destroys members in reverse order.
  ink::MutableMesh mesh_;
  ink::strokes_internal::BrushTipExtruder extruder_;
  float brush_epsilon_page_ = 0.0f;
  bool started_ = false;
};

}  // namespace margelo::nitro::inksignpdf
