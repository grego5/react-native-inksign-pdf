#include "modeling/SignatureBrushTipModeler.hpp"
#include "ink-engine/tests/support/TestSupport.hpp"
#include "upstream/UpstreamStrokeGeometry.hpp"
#include "upstream/UpstreamStrokeOutput.hpp"

#include "absl/types/span.h"
#include "ink/strokes/primitives/brush_tip_extruder.h"
#include "ink/strokes/primitives/stroke_vertex.h"

#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <vector>

using namespace margelo::nitro::inksignpdf;

namespace {

detail::CenterlineState state(double x, double speed, double time,
                              std::size_t source) {
  return {.position = {x, 0.0},
          .velocity = {speed, 0.0},
          .time = time,
          .rawSourceIndex = source,
          .modeledSourceIndex = source};
}

std::vector<detail::CurrentInkModeledInput> modeledInputs(
    const std::vector<detail::CenterlineState>& states) {
  std::vector<detail::CurrentInkModeledInput> modeled;
  modeled.reserve(states.size());
  for (const auto& value : states)
    modeled.push_back({.state = value});
  return modeled;
}

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void requireSameMesh(const ink::MutableMesh& first,
                     const ink::MutableMesh& second) {
  require(first.RawVertexData() == second.RawVertexData(),
          "policy owner changed upstream vertex output");
  require(first.RawIndexData() == second.RawIndexData(),
          "policy owner changed upstream index output");
}

void requireSameGeometry(const UpstreamStrokeGeometry& first,
                         const UpstreamStrokeGeometry& second) {
  requireSameMesh(first.mesh(), second.mesh());
  const auto firstOutlines = first.outlines();
  const auto secondOutlines = second.outlines();
  require(firstOutlines.size() == secondOutlines.size(),
          "rollback changed upstream outline count");
  for (std::size_t index = 0; index < firstOutlines.size(); ++index) {
    require(firstOutlines[index].GetIndexCounts().left ==
                secondOutlines[index].GetIndexCounts().left &&
            firstOutlines[index].GetIndexCounts().right ==
                secondOutlines[index].GetIndexCounts().right,
            "rollback changed upstream outline counts");
    require(firstOutlines[index].GetIndices() ==
                secondOutlines[index].GetIndices(),
            "rollback changed upstream outline indices");
  }
  const auto firstBounds = first.bounds().AsRect();
  const auto secondBounds = second.bounds().AsRect();
  require(firstBounds.has_value() == secondBounds.has_value(),
          "rollback changed upstream bounds presence");
  if (firstBounds.has_value()) {
    require(firstBounds->XMin() == secondBounds->XMin() &&
                firstBounds->YMin() == secondBounds->YMin() &&
                firstBounds->XMax() == secondBounds->XMax() &&
                firstBounds->YMax() == secondBounds->YMax(),
            "rollback changed upstream bounds");
  }
}

void checkStateShape(
    const std::vector<ModeledPoint>& points,
    std::span<const UpstreamStrokeGeometry::BrushTipState> upstream) {
  const std::size_t sourceStart = points.size() - upstream.size();
  for (std::size_t index = 0; index < upstream.size(); ++index) {
    const auto& tip = upstream[index];
    CHECK(tip.position.x == static_cast<float>(points[sourceStart + index].point.x));
    CHECK(tip.position.y == static_cast<float>(points[sourceStart + index].point.y));
    CHECK(tip.height == tip.width);
    CHECK(tip.corner_rounding == 1.0f);
    CHECK(tip.rotation == ink::Angle{});
    CHECK(tip.slant == ink::Angle{});
    CHECK(tip.pinch == 0.0f);
    if (sourceStart + index < points.size())
      CHECK(tip.position.x ==
            static_cast<float>(points[sourceStart + index].point.x));
  }
}

void testPolicyProducesUpstreamStates() {
  const InkStrokeConfig config{.minWidth = 2.0,
                             .maxWidth = 4.0,
                             .logicalDisplayUnitsPerPageUnit = 2.0,
                             .smoothing = 0.0};
  detail::SignatureBrushTipModeler brush(config);
  InkStrokeWorkStats stats;
  const std::vector<detail::CenterlineState> real{
      state(0.0, 0.0, 0.000, 0), state(50.0, 300.0, 0.010, 1),
      state(100.0, 900.0, 0.020, 2), state(150.0, 1200.0, 0.030, 3)};
  const auto modeled = modeledInputs(real);

  const auto update = brush.update({modeled, 0, 2, 900.0}, stats);
  CHECK(update.newFixedUpstreamStates.size() == 1);
  CHECK(update.volatileUpstreamStates.size() == real.size() - 1);
  CHECK(update.newFixedUpstreamStates.front().position.x == 0.0f);
  checkStateShape(brush.modeledPoints(), update.volatileUpstreamStates);

  // A terminal round-tip state is deliberately passed through to upstream;
  // BrushTipExtruder owns the cap and closure semantics.
  const auto finished = brush.finish({modeled, 2, modeled.size(), 1200.0},
                                     stats);
  CHECK(!finished.volatileUpstreamStates.empty());
  CHECK(finished.volatileUpstreamStates.back().width > 0.0f);
  CHECK(finished.volatileUpstreamStates.back().height ==
        finished.volatileUpstreamStates.back().width);
  CHECK(finished.volatileUpstreamStates.back().position.x ==
        static_cast<float>(brush.modeledPoints().back().point.x));
}

void testUpstreamRollbackAndPredictionSplit() {
  const InkStrokeConfig config{.minWidth = 2.0,
                             .maxWidth = 4.0,
                             .logicalDisplayUnitsPerPageUnit = 10.0,
                             .smoothing = 0.0};
  detail::SignatureBrushTipModeler brush(config);
  InkStrokeWorkStats stats;
  std::vector<detail::CenterlineState> real{
      state(0.0, 0.0, 0.00, 0), state(20.0, 500.0, 0.01, 1),
      state(45.0, 700.0, 0.02, 2), state(75.0, 900.0, 0.03, 3)};
  auto modeled = modeledInputs(real);
  auto live = brush.update({modeled, 0, 3, 900.0}, stats);
  CHECK(live.newFixedUpstreamStates.size() == 2);
  CHECK(live.volatileUpstreamStates.size() == 2);

  UpstreamStrokeGeometry geometry;
  geometry.start(0.1f, 1.0f);
  geometry.extend(live.newFixedUpstreamStates,
                  live.volatileUpstreamStates);

  ink::MutableMesh directMesh(
      ink::strokes_internal::StrokeVertex::FullMeshFormat());
  ink::strokes_internal::BrushTipExtruder direct;
  direct.StartStroke(geometry.brushEpsilonPageUnits(), false, directMesh);
  direct.ExtendStroke(
      absl::MakeConstSpan(live.newFixedUpstreamStates.data(),
                          live.newFixedUpstreamStates.size()),
      absl::MakeConstSpan(live.volatileUpstreamStates.data(),
                          live.volatileUpstreamStates.size()));
  requireSameMesh(geometry.mesh(), directMesh);

  const auto before = brush.modeledPoints();
  const auto beforeStats = stats;
  auto predicted = state(95.0, 1000.0, 0.04, 4);
  predicted.predicted = true;
  const auto preview = brush.predict(std::span(&predicted, 1));
  CHECK(preview.newFixedUpstreamStates.empty());
  CHECK(preview.volatileUpstreamStates.size() == 3);
  CHECK(preview.volatileUpstreamStates.front().position.x == 45.0f);
  CHECK(preview.volatileUpstreamStates.back().position.x == 95.0f);
  CHECK(brush.modeledPoints().size() == before.size());
  CHECK(brush.modeledPoints().front().radius == before.front().radius);
  CHECK(stats.widthPointsProcessed == beforeStats.widthPointsProcessed);

  // The upstream owner receives the complete replaceable real tail followed
  // by prediction. No predicted call is allowed to advance its fixed state.
  geometry.extend({}, preview.volatileUpstreamStates);

  auto revisedPrediction = state(100.0, 1100.0, 0.045, 5);
  revisedPrediction.predicted = true;
  const auto revisedPreview =
      brush.predict(std::span(&revisedPrediction, 1));
  CHECK(revisedPreview.newFixedUpstreamStates.empty());
  CHECK(revisedPreview.volatileUpstreamStates.size() == 3);
  CHECK(revisedPreview.volatileUpstreamStates.front().position.x == 45.0f);
  CHECK(revisedPreview.volatileUpstreamStates.back().position.x == 100.0f);
  geometry.extend({}, revisedPreview.volatileUpstreamStates);

  // Feeding the replacement suffix to the same owner rolls back only the
  // volatile geometry. The fixed tip sequence remains accepted and is not
  // resubmitted.
  real[3].velocity.x = 600.0;
  modeled = modeledInputs(real);
  const auto replacement = brush.update({modeled, 3, 3, 600.0}, stats);
  CHECK(replacement.newFixedUpstreamStates.empty());
  CHECK(replacement.volatileUpstreamStates.size() == 2);
  geometry.extend(replacement.newFixedUpstreamStates,
                  replacement.volatileUpstreamStates);

  const auto finished = brush.finish(
      {modeled, modeled.size(), modeled.size(), 600.0}, stats);
  geometry.extend(finished.newFixedUpstreamStates,
                  finished.volatileUpstreamStates);
  CHECK(finished.volatileUpstreamStates.back().width > 0.0f);

  // Rebuild the authoritative final state from scratch and compare the actual
  // prediction/replacement/finish sequence, including mesh, outlines, and
  // bounds.
  detail::SignatureBrushTipModeler authoritative(config);
  InkStrokeWorkStats authoritativeStats;
  const auto authoritativeUpdate = authoritative.update(
      {modeled, 0, modeled.size(), 600.0}, authoritativeStats);
  UpstreamStrokeGeometry reconstructed;
  reconstructed.start(0.1f, 1.0f);
  reconstructed.extend(authoritativeUpdate.newFixedUpstreamStates,
                        authoritativeUpdate.volatileUpstreamStates);
  const auto authoritativeFinish = authoritative.finish(
      {modeled, modeled.size(), modeled.size(), 600.0}, authoritativeStats);
  reconstructed.extend(authoritativeFinish.newFixedUpstreamStates,
                       authoritativeFinish.volatileUpstreamStates);
  requireSameGeometry(geometry, reconstructed);
  require(geometry.mesh().VertexCount() > 0,
          "upstream rollback discarded all replacement geometry");
}

void testUpstreamBehaviorBranches() {
  // BrushTipExtruder breaks only when both dimensions are strictly below its
  // epsilon; equality and a single narrow dimension remain drawable.
  UpstreamStrokeGeometry threshold;
  threshold.start(0.1f, 1.0f);
  const auto below = UpstreamStrokeGeometry::BrushTipState{
      .position = {}, .width = 0.099f, .height = 0.099f,
      .corner_rounding = 1.0f, .rotation = {}, .slant = {}, .pinch = 0.0f};
  threshold.extend({}, absl::MakeConstSpan(&below, 1));
  CHECK(threshold.mesh().VertexCount() == 0);

  threshold.reset();
  const auto equal = UpstreamStrokeGeometry::BrushTipState{
      .position = {}, .width = 0.1f, .height = 0.1f,
      .corner_rounding = 1.0f, .rotation = {}, .slant = {}, .pinch = 0.0f};
  threshold.extend({}, absl::MakeConstSpan(&equal, 1));
  CHECK(threshold.mesh().VertexCount() > 0);

  threshold.reset();
  const auto mixed = UpstreamStrokeGeometry::BrushTipState{
      .position = {}, .width = 0.1f, .height = 0.2f,
      .corner_rounding = 1.0f, .rotation = {}, .slant = {}, .pinch = 0.0f};
  threshold.extend({}, absl::MakeConstSpan(&mixed, 1));
  CHECK(threshold.mesh().VertexCount() > 0);

  // Equal center positions are retained by policy and still produce a
  // stationary upstream shape rather than being treated as a missing sample.
  const InkStrokeConfig config{.minWidth = 2.0,
                             .maxWidth = 4.0,
                             .logicalDisplayUnitsPerPageUnit = 1.0,
                             .smoothing = 0.0};
  detail::SignatureBrushTipModeler brush(config);
  InkStrokeWorkStats stats;
  const std::vector<detail::CenterlineState> zeroTravel{
      state(10.0, 0.0, 0.00, 0), state(10.0, 0.0, 0.01, 1)};
  const auto modeledZeroTravel = modeledInputs(zeroTravel);
  const auto zeroTravelUpdate =
      brush.update({modeledZeroTravel, 0, modeledZeroTravel.size(), 0.0}, stats);
  CHECK(brush.modeledPoints().size() == 2);
  CHECK(zeroTravelUpdate.volatileUpstreamStates.size() == 2);
  CHECK(zeroTravelUpdate.volatileUpstreamStates[0].position.x ==
        zeroTravelUpdate.volatileUpstreamStates[1].position.x);

  UpstreamStrokeGeometry stationary;
  stationary.start(0.1f, 1.0f);
  stationary.extend(zeroTravelUpdate.newFixedUpstreamStates,
                    zeroTravelUpdate.volatileUpstreamStates);
  CHECK(stationary.mesh().VertexCount() > 0);

  // A stationary dot is a separate one-state stroke. The next moving stroke
  // starts from a fresh policy owner and does not inherit dot geometry/state.
  brush.reset();
  stats = {};
  const detail::NormalizedInput dotInput{.eventType = InkStrokeEventType::Down,
                                         .position = {3.0, 4.0},
                                         .time = 0.1};
  const auto dot = brush.finishDot(dotInput, 1.5);
  CHECK(dot.volatileUpstreamStates.size() == 1);
  CHECK(dot.volatileUpstreamStates.front().width == 3.0f);

  brush.reset();
  stats = {};
  const std::vector<detail::CenterlineState> moving{
      state(3.0, 0.0, 0.20, 0), state(8.0, 500.0, 0.21, 1)};
  const auto modeledMoving = modeledInputs(moving);
  const auto movingUpdate =
      brush.finish({modeledMoving, 0, modeledMoving.size(), 500.0}, stats);
  CHECK(movingUpdate.volatileUpstreamStates.size() == moving.size());
  CHECK(movingUpdate.volatileUpstreamStates.front().position.x == 3.0f);
  CHECK(movingUpdate.volatileUpstreamStates.back().width > 0.0f);

  // Terminal taper ends in a positive, dynamically sized rounded state.
  brush.reset();
  stats = {};
  const std::vector<detail::CenterlineState> tapered{
      state(0.0, 0.0, 0.00, 0), state(40.0, 960.0, 0.04, 1),
      state(80.0, 960.0, 0.08, 2), state(120.0, 960.0, 0.12, 3)};
  const auto modeledTapered = modeledInputs(tapered);
  const auto taperedUpdate =
      brush.finish({modeledTapered, 0, modeledTapered.size(), 960.0}, stats);
  CHECK(taperedUpdate.newFixedUpstreamStates.size() +
            taperedUpdate.volatileUpstreamStates.size() ==
        tapered.size());
  CHECK(taperedUpdate.volatileUpstreamStates.back().width > 0.0f);

  UpstreamStrokeGeometry taperedGeometry;
  taperedGeometry.start(0.1f, 1.0f);
  taperedGeometry.extend(taperedUpdate.newFixedUpstreamStates,
                         taperedUpdate.volatileUpstreamStates);
  CHECK(taperedGeometry.mesh().VertexCount() > 0);
  CHECK(!taperedGeometry.outlines().empty());
  CHECK(taperedGeometry.outlines().back().GetIndexCounts().left > 0);
  CHECK(taperedGeometry.outlines().back().GetIndexCounts().right > 0);
  const auto taperedBounds = taperedGeometry.bounds().AsRect();
  CHECK(taperedBounds.has_value());
  CHECK(taperedBounds->XMax() >= 120.0f);
  CHECK(taperedBounds->XMax() < 122.1f);

  const auto contours = extractUpstreamContours(taperedGeometry, tapered.size());
  CHECK(contours.size() == 1);
  CHECK(contours.front().path.closed);
  bool forwardUpper = false;
  bool forwardLower = false;
  for (const auto& segment : contours.front().path.segments) {
    for (const auto point : {segment.p0, segment.p3}) {
      if (point.x <= 120.0) continue;
      forwardUpper = forwardUpper || point.y > 0.0;
      forwardLower = forwardLower || point.y < 0.0;
    }
  }
  CHECK(forwardUpper);
  CHECK(forwardLower);
}

void testStationaryDotUsesSameTipContract() {
  detail::SignatureBrushTipModeler brush(
      InkStrokeConfig{.minWidth = 2.0, .maxWidth = 4.0, .smoothing = 0.0});
  const detail::NormalizedInput input{.eventType = InkStrokeEventType::Down,
                                      .position = {3.0, 4.0}, .time = 0.1};
  const auto dot = brush.finishDot(input, 1.5);
  CHECK(dot.newFixedUpstreamStates.empty());
  CHECK(dot.volatileUpstreamStates.size() == 1);
  CHECK(dot.volatileUpstreamStates.front().width == 3.0f);
  CHECK(dot.volatileUpstreamStates.front().height == 3.0f);
  CHECK(dot.volatileUpstreamStates.front().position.x == 3.0f);
  CHECK(dot.volatileUpstreamStates.front().position.y == 4.0f);
}

}  // namespace

int main() {
  testUpstreamRollbackAndPredictionSplit();
  testUpstreamBehaviorBranches();
  testPolicyProducesUpstreamStates();
  testStationaryDotUsesSameTipContract();
  return 0;
}
