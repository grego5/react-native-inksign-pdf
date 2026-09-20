#include "upstream/UpstreamStrokeGeometry.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

#include "absl/types/span.h"
#include "ink/strokes/primitives/brush_tip_extruder.h"
#include "ink/strokes/primitives/brush_tip_extrusion.h"
#include "ink/strokes/primitives/constrain_brush_tip_extrusion.h"
#include "ink/strokes/primitives/stroke_vertex.h"

namespace {

using Owner = margelo::nitro::inksignpdf::UpstreamStrokeGeometry;
using State = Owner::BrushTipState;
using UpstreamExtruder = ink::strokes_internal::BrushTipExtruder;
using TipExtrusion = ink::strokes_internal::BrushTipExtrusion;
using ConstraintResult =
    ink::strokes_internal::ConstrainedBrushTipExtrusion::ResultType;

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

State state(float x, float y, float width, float height,
            std::size_t source = 0) {
  State result{
      .position = {.x = x, .y = y},
      .width = width,
      .height = height,
      .corner_rounding = 1.0f,
      .rotation = {},
      .slant = {},
      .pinch = 0.0f,
  };
  result.texture_animation_progress_offset = static_cast<float>(source);
  return result;
}

void requireSameMesh(const ink::MutableMesh& first, const ink::MutableMesh& second) {
  require(first.Format() == second.Format(), "mesh formats differ");
  require(first.RawVertexData().size() == second.RawVertexData().size(),
          "mesh vertex bytes differ");
  require(first.RawIndexData().size() == second.RawIndexData().size(),
          "mesh index bytes differ");
  require(first.RawVertexData() == second.RawVertexData(),
          "mesh vertex data differs");
  require(first.RawIndexData() == second.RawIndexData(),
          "mesh index data differs");
}

void requireSameOutlines(
    absl::Span<const ink::strokes_internal::StrokeOutline> first,
    absl::Span<const ink::strokes_internal::StrokeOutline> second) {
  require(first.size() == second.size(), "outline counts differ");
  for (std::size_t i = 0; i < first.size(); ++i) {
    require(first[i].GetIndexCounts().left == second[i].GetIndexCounts().left,
            "outline left counts differ");
    require(first[i].GetIndexCounts().right == second[i].GetIndexCounts().right,
            "outline right counts differ");
    require(first[i].GetIndices() == second[i].GetIndices(),
            "outline indices differ");
  }
}

void compareOwnerWithDirect(const std::vector<State>& fixed,
                            const std::vector<State>& volatile_states,
                            float scale = 2.0f) {
  Owner owner;
  owner.start(0.1f, scale);
  owner.extend(absl::MakeConstSpan(fixed), absl::MakeConstSpan(volatile_states));

  ink::MutableMesh direct_mesh(
      ink::strokes_internal::StrokeVertex::FullMeshFormat());
  UpstreamExtruder direct;
  direct.StartStroke(owner.brushEpsilonPageUnits(), false, direct_mesh);
  direct.ExtendStroke(absl::MakeConstSpan(fixed),
                      absl::MakeConstSpan(volatile_states));

  requireSameMesh(owner.mesh(), direct_mesh);
  requireSameOutlines(owner.outlines(), direct.GetOutlines());
  const auto& owner_bounds = owner.bounds().AsRect();
  const auto& direct_bounds = direct.GetBounds().AsRect();
  require(owner_bounds.has_value() == direct_bounds.has_value(),
          "bounds presence differs");
  if (owner_bounds.has_value()) {
    require(owner_bounds->XMin() == direct_bounds->XMin() &&
                owner_bounds->YMin() == direct_bounds->YMin() &&
                owner_bounds->XMax() == direct_bounds->XMax() &&
                owner_bounds->YMax() == direct_bounds->YMax(),
            "bounds differ");
  }
}

void requireSameGeometry(const Owner& first, const Owner& second) {
  requireSameMesh(first.mesh(), second.mesh());
  requireSameOutlines(first.outlines(), second.outlines());
  const auto firstBounds = first.bounds().AsRect();
  const auto secondBounds = second.bounds().AsRect();
  require(firstBounds.has_value() == secondBounds.has_value(),
          "owner bounds presence differs");
  if (firstBounds.has_value()) {
    require(firstBounds->XMin() == secondBounds->XMin() &&
                firstBounds->YMin() == secondBounds->YMin() &&
                firstBounds->XMax() == secondBounds->XMax() &&
                firstBounds->YMax() == secondBounds->YMax(),
            "owner bounds differ");
  }
}

void testEpsilonConversionAndStrictThreshold() {
  Owner owner;
  owner.start(0.1f, 2.0f);
  require(owner.brushEpsilonPageUnits() == 0.05f,
          "display epsilon was not converted to page units");

  const std::vector<State> below{state(0, 0, 0.049f, 0.049f)};
  owner.extend(absl::MakeConstSpan(below), {});
  require(owner.mesh().VertexCount() == 0, "below-epsilon state was extruded");

  owner.reset();
  const std::vector<State> equal{state(0, 0, 0.05f, 0.05f)};
  owner.extend(absl::MakeConstSpan(equal), {});
  require(owner.mesh().VertexCount() > 0,
          "equal-epsilon state was incorrectly treated as a break");

  owner.reset();
  const std::vector<State> mixed{state(0, 0, 0.05f, 0.1f)};
  owner.extend(absl::MakeConstSpan(mixed), {});
  require(owner.mesh().VertexCount() > 0,
          "strict two-dimension threshold was not preserved");

  // Exercise each dimension independently around the strict two-dimensional
  // break-point predicate, and compare every result with direct upstream use.
  compareOwnerWithDirect({state(0, 0, 0.049f, 0.101f)}, {});
  compareOwnerWithDirect({state(0, 0, 0.101f, 0.049f)}, {});
  compareOwnerWithDirect({state(0, 0, 0.051f, 0.051f)}, {});

  // A later below-epsilon state must split the circular stroke, while the
  // states on either side remain authoritative upstream output.
  const std::vector<State> tapering{
      state(0, 0, 0.2f, 0.2f), state(1, 0, 0.101f, 0.101f),
      state(2, 0, 0.049f, 0.049f), state(3, 0, 0.2f, 0.2f)};
  compareOwnerWithDirect(tapering, {});
}

void testUpstreamCasesAndVolatileRollback() {
  compareOwnerWithDirect(
      {state(0, 0, 4, 4), state(8, 0, 2, 2), state(12, 2, 3, 1)}, {});
  compareOwnerWithDirect(
      {state(0, 0, 4, 4), state(1, 0, 1, 1), state(2, 0, 7, 7),
       state(4, 0, 0, 0)},
      {});
  compareOwnerWithDirect(
      {state(0, 0, 4, 4)}, {state(8, 0, 2, 2), state(12, 2, 0, 0)});

  Owner owner;
  owner.start(0.1f, 2.0f);
  const std::vector<State> fixed{state(0, 0, 4, 4)};
  const std::vector<State> first_volatile{state(8, 0, 2, 2)};
  const std::vector<State> replacement{state(4, 4, 1, 1), state(12, 2, 0, 0)};
  owner.extend(absl::MakeConstSpan(fixed), absl::MakeConstSpan(first_volatile));
  owner.extend(absl::MakeConstSpan(fixed), absl::MakeConstSpan(replacement));
  require(owner.mesh().VertexCount() > 0, "volatile replacement lost geometry");
  compareOwnerWithDirect(fixed, replacement);
}

void testOwnedSnapshotAndLifecycle() {
  Owner owner;
  owner.start(0.1f, 1.0f);
  const std::vector<State> states{state(0, 0, 3, 3), state(5, 0, 2, 2)};
  owner.extend(absl::MakeConstSpan(states), {});
  auto snapshot = owner.snapshot();
  requireSameMesh(snapshot.mesh, owner.mesh());
  require(snapshot.outlines.size() == owner.outlines().size(),
          "snapshot outline count differs");
  require(snapshot.outlines.front().indices.size() ==
              owner.outlines().front().GetIndices().size(),
          "snapshot outline indices were not copied");

  owner.reset();
  require(owner.mesh().VertexCount() == 0 && owner.mesh().TriangleCount() == 0,
          "reset retained mutable mesh geometry");
  require(owner.outlines().size() == 1,
          "reset did not retain the upstream empty outline contract");
}

void testInvalidStart() {
  Owner owner;
  bool threw = false;
  try {
    owner.start(0.1f, 0.0f);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  require(threw, "invalid page-to-view scale was accepted");
}

void testNonCircularConstraintsAndIntersections() {
  const State first = state(0, 0, 4, 2);
  const State constrained = state(0.2f, 0.2f, 2, 4);
  const TipExtrusion firstExtrusion(first, 0.1f);
  const TipExtrusion constrainedExtrusion(constrained, 0.1f);

  require(TipExtrusion::EvaluateTangentQuality(
              firstExtrusion, constrainedExtrusion, 0.01f) ==
              TipExtrusion::TangentQuality::
                  kBadTangentsJoinedShapeDoesNotCoverInputShapes,
          "noncircular bad-tangent case was not identified");
  const auto constrainedResult =
      ink::strokes_internal::ConstrainBrushTipExtrusion(
          firstExtrusion, constrainedExtrusion, 0.1f, 7);
  require(constrainedResult.result_type ==
              ConstraintResult::kConstrainedExtrusionFound &&
              constrainedResult.lerp_amount > 0.0f &&
              constrainedResult.lerp_amount < 1.0f,
          "noncircular state was not constrained");
  compareOwnerWithDirect({first, constrained}, {});

  const State smaller = state(0, 0, 2, 1);
  const TipExtrusion smallerExtrusion(smaller, 0.1f);
  const auto smallerResult = ink::strokes_internal::ConstrainBrushTipExtrusion(
      firstExtrusion, smallerExtrusion, 0.1f, 7);
  require(smallerResult.result_type ==
              ConstraintResult::kLastExtrusionContainsProposedExtrusion,
          "contained noncircular state was not rejected");
  Owner rejected;
  rejected.start(0.1f, 2.0f);
  rejected.extend({first, smaller}, {});
  Owner firstOnly;
  firstOnly.start(0.1f, 2.0f);
  firstOnly.extend({first}, {});
  requireSameGeometry(rejected, firstOnly);

  const State larger = state(0, 0, 8, 4);
  const TipExtrusion largerExtrusion(larger, 0.1f);
  const auto largerResult = ink::strokes_internal::ConstrainBrushTipExtrusion(
      firstExtrusion, largerExtrusion, 0.1f, 7);
  require(largerResult.result_type ==
              ConstraintResult::kProposedExtrusionContainsLastExtrusion,
          "containing noncircular state did not create the upstream break");
  compareOwnerWithDirect({first, larger}, {});

  const State deferred = state(0.05f, 0.05f, 2, 4);
  const TipExtrusion deferredExtrusion(deferred, 0.1f);
  const auto deferredResult =
      ink::strokes_internal::ConstrainBrushTipExtrusion(
          firstExtrusion, deferredExtrusion, 0.1f, 7);
  require(deferredResult.result_type ==
              ConstraintResult::kConstrainedExtrusionFound &&
              deferredResult.lerp_amount < 0.1f,
          "deferral fixture did not produce a near-zero constraint");

  const State trailing = state(10, 0, 4, 2);
  Owner deferredOwner;
  deferredOwner.start(0.1f, 2.0f);
  deferredOwner.extend({first}, {deferred, trailing});
  Owner deferredExpected;
  deferredExpected.start(0.1f, 2.0f);
  deferredExpected.extend({first}, {trailing});
  requireSameGeometry(deferredOwner, deferredExpected);

  Owner finalOwner;
  finalOwner.start(0.1f, 2.0f);
  finalOwner.extend({first, deferred}, {});
  require(finalOwner.mesh().VertexCount() > firstOnly.mesh().VertexCount(),
          "final-state deferral exception did not accept the last state");
  compareOwnerWithDirect({first, deferred}, {});

  // Crossing noncircular tips exercise upstream's self-intersection correction
  // while retaining the same owner/direct-output equivalence requirement.
  const std::vector<State> crossing{
      state(0, 0, 4, 2), state(20, 20, 4, 2), state(0, 20, 4, 2),
      state(20, 0, 4, 2), state(0, 0, 4, 2)};
  compareOwnerWithDirect(crossing, {});
  Owner intersectionOwner;
  intersectionOwner.start(0.1f, 2.0f);
  intersectionOwner.extend(absl::MakeConstSpan(crossing), {});
  require(intersectionOwner.mesh().ValidateTriangles().ok(),
          "intersection correction produced invalid mesh triangles");
}

}  // namespace

int main() {
  testEpsilonConversionAndStrictThreshold();
  testUpstreamCasesAndVolatileRollback();
  testOwnedSnapshotAndLifecycle();
  testInvalidStart();
  testNonCircularConstraintsAndIntersections();
  return 0;
}
