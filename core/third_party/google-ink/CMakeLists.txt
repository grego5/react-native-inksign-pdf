cmake_minimum_required(VERSION 3.22)

# This target is deliberately limited to the BrushTipExtruder dependency
# closure. Rendering, JNI, particle-brush, and behavior-interpreter sources are
# not part of the product dependency.
add_library(GoogleInkGeometry STATIC
  ink/color/color.cc
  ink/color/color_space.cc
  ink/types/duration.cc
  ink/geometry/affine_transform.cc
  ink/geometry/angle.cc
  ink/geometry/distance.cc
  ink/geometry/envelope.cc
  ink/geometry/intersects.cc
  ink/geometry/mesh.cc
  ink/geometry/mesh_format.cc
  ink/geometry/mesh_packing_types.cc
  ink/geometry/mutable_mesh.cc
  ink/geometry/partitioned_mesh.cc
  ink/geometry/point.cc
  ink/geometry/quad.cc
  ink/geometry/rect.cc
  ink/geometry/segment.cc
  ink/geometry/triangle.cc
  ink/geometry/vec.cc
  ink/geometry/internal/algorithms.cc
  ink/geometry/internal/circle.cc
  ink/geometry/internal/intersects_internal.cc
  ink/geometry/internal/legacy_segment_intersection.cc
  ink/geometry/internal/legacy_triangle_contains.cc
  ink/geometry/internal/legacy_vector_utils.cc
  ink/geometry/internal/lerp.cc
  ink/geometry/internal/mesh_packing.cc
  ink/geometry/internal/modulo.cc
  ink/geometry/internal/outline_processing.cc
  ink/geometry/internal/static_rtree.cc
  ink/strokes/internal/brush_tip_extruder.cc
  ink/strokes/internal/brush_tip_extrusion.cc
  ink/strokes/internal/brush_tip_shape.cc
  ink/strokes/internal/brush_tip_state.cc
  ink/strokes/internal/circular_extrusion_helpers.cc
  ink/strokes/internal/constrain_brush_tip_extrusion.cc
  ink/strokes/internal/rounded_polygon.cc
  ink/strokes/internal/stroke_outline.cc
  ink/strokes/internal/stroke_shape_update.cc
  ink/strokes/internal/stroke_vertex.cc
  ink/strokes/internal/brush_tip_extruder/derivative_calculator.cc
  ink/strokes/internal/brush_tip_extruder/derivative_calculator_helpers.cc
  ink/strokes/internal/brush_tip_extruder/directed_partial_outline.cc
  ink/strokes/internal/brush_tip_extruder/extruded_vertex.cc
  ink/strokes/internal/brush_tip_extruder/find_clockwise_winding_segment.cc
  ink/strokes/internal/brush_tip_extruder/geometry.cc
  ink/strokes/internal/brush_tip_extruder/mutable_mesh_view.cc
  ink/strokes/internal/brush_tip_extruder/simplify.cc
)

target_include_directories(GoogleInkGeometry PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(GoogleInkGeometry PUBLIC
  absl::algorithm
  absl::check
  absl::core_headers
  absl::flat_hash_map
  absl::flat_hash_set
  absl::function_ref
  absl::inlined_vector
  absl::log
  absl::span
  absl::status
  absl::status_builder
  absl::statusor
  absl::strings
  absl::time
)

target_compile_features(GoogleInkGeometry PUBLIC cxx_std_20)
if(MSVC)
  target_compile_options(GoogleInkGeometry PRIVATE /W4 /permissive- /Zc:__cplusplus)
else()
  target_compile_options(GoogleInkGeometry PRIVATE -Wall -Wextra -Wpedantic)
endif()
