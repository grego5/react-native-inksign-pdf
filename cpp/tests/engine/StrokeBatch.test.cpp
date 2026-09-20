#include "InkEngine.hpp"
#include "input/CommittedCenterline.hpp"
#include "tests/support/TestSupport.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <span>
#include <vector>

using namespace margelo::nitro::inksignpdf;

namespace {

bool nearlyEqual(double first, double second) {
  return std::abs(first - second) <=
      1e-9 * std::max({1.0, std::abs(first), std::abs(second)});
}

InkStrokeInput input(InkStrokeEventType type, double x, double y, double time) {
  return {.eventType = type,
          .position = {x, y},
          .time = time,
          .pressure = 0.5,
          .tilt = -1.0,
          .orientation = -1.0};
}

bool same(const ModeledPoint& first, const ModeledPoint& second) {
  return nearlyEqual(first.point.x, second.point.x) &&
      nearlyEqual(first.point.y, second.point.y) &&
      nearlyEqual(first.tangent.x, second.tangent.x) &&
      nearlyEqual(first.tangent.y, second.tangent.y) &&
      nearlyEqual(first.time, second.time) &&
      nearlyEqual(first.distance, second.distance) &&
      nearlyEqual(first.runningLength, second.runningLength) &&
      nearlyEqual(first.velocity, second.velocity) &&
      nearlyEqual(first.acceleration.x, second.acceleration.x) &&
      nearlyEqual(first.acceleration.y, second.acceleration.y) &&
      nearlyEqual(first.pressure, second.pressure) &&
      nearlyEqual(first.tilt, second.tilt) &&
      nearlyEqual(first.orientation, second.orientation) &&
      nearlyEqual(first.radius, second.radius);
}

bool same(const std::vector<ModeledPoint>& first,
          const std::vector<ModeledPoint>& second) {
  if (first.size() != second.size()) return false;
  for (std::size_t index = 0; index < first.size(); ++index)
    if (!same(first[index], second[index])) return false;
  return true;
}

bool same(const StrokeContourCollection& first,
          const StrokeContourCollection& second) {
  if (first.size() != second.size()) return false;
  for (std::size_t contour = 0; contour < first.size(); ++contour) {
    const auto& left = first[contour];
    const auto& right = second[contour];
    if (left.sourceStart != right.sourceStart ||
        left.sourceEnd != right.sourceEnd ||
        left.path.closed != right.path.closed ||
        left.path.segments.size() != right.path.segments.size()) return false;
    for (std::size_t segment = 0; segment < left.path.segments.size();
         ++segment) {
      const auto& a = left.path.segments[segment];
      const auto& b = right.path.segments[segment];
      if (!nearlyEqual(a.p0.x, b.p0.x) || !nearlyEqual(a.p0.y, b.p0.y) ||
          !nearlyEqual(a.c1.x, b.c1.x) || !nearlyEqual(a.c1.y, b.c1.y) ||
          !nearlyEqual(a.c2.x, b.c2.x) || !nearlyEqual(a.c2.y, b.c2.y) ||
          !nearlyEqual(a.p3.x, b.p3.x) || !nearlyEqual(a.p3.y, b.p3.y) ||
          a.sourceStart != b.sourceStart || a.sourceEnd != b.sourceEnd)
        return false;
    }
  }
  return true;
}

InkStrokeFrame runStroke(std::size_t batchSize, const std::vector<InkStrokeInput>& moves) {
  InkEngine engine;
  InkStrokeFrame frame;
  CHECK(engine.begin(input(InkStrokeEventType::Down, 0.0, 0.0, 0.0), frame).ok());
  for (std::size_t start = 0; start < moves.size(); start += batchSize) {
    const std::size_t count = std::min(batchSize, moves.size() - start);
    CHECK(engine.updateBatch(
              std::span<const InkStrokeInput>(moves.data() + start, count), frame)
              .ok());
  }
  CHECK(engine.end(input(InkStrokeEventType::Up, moves.back().position.x,
                        moves.back().position.y, moves.back().time + 0.01),
                   frame)
            .ok());
  return frame;
}

}  // namespace

int main() {
  // A fast flick starts at the minimum radius and obeys the causal spatial
  // radius bound for both growth and contraction.
  {
    const InkStrokeConfig config{
        .minWidth = 2.0, .maxWidth = 4.0, .smoothing = 0.0};
    InkEngine engine(config);
    engine.enableDiagnostics(true);
    InkStrokeFrame frame;
    CHECK(engine.begin(input(InkStrokeEventType::Down, 0, 0, 0), frame).ok());
    const std::array flick{
        input(InkStrokeEventType::Move, 0.5, 0, 0.004),
        input(InkStrokeEventType::Move, 2, 0, 0.008),
        input(InkStrokeEventType::Move, 10, 0, 0.012),
        input(InkStrokeEventType::Move, 30, 0, 0.020),
        input(InkStrokeEventType::Move, 30.5, 0, 0.020),
        input(InkStrokeEventType::Up, 60, 0, 0.032)};
    CHECK(engine.endBatch(flick, frame).ok());
    const auto& samples = engine.diagnosticSamples();
    CHECK(samples.size() >= 2);
    const auto& first = samples.front();
    CHECK(nearlyEqual(first.radius, config.minWidth * 0.5));
    CHECK(first.responseAlpha == 0.0);
    for (std::size_t index = 1; index < samples.size(); ++index) {
      const auto& sample = samples[index];
      const double growthResponseDistance = config.maxWidth * 6.0;
      const double contractionResponseDistance = config.maxWidth * 2.0;
      CHECK(nearlyEqual(sample.responseDistancePage, growthResponseDistance) ||
            nearlyEqual(sample.responseDistancePage,
                        contractionResponseDistance));
      const double expectedAlpha = sample.segmentDistance > 0.0
          ? -std::expm1(-sample.segmentDistance / sample.responseDistancePage)
          : 0.0;
      CHECK(nearlyEqual(sample.responseAlpha, expectedAlpha));
    }
  }
  // A covered terminal contact still publishes usable geometry and permits
  // the caller to begin the next stroke with the same frame.
  {
    InkEngine engine({.minWidth = 2.0, .maxWidth = 2.0, .smoothing = 0.0});
    InkStrokeFrame frame;
    CHECK(engine.begin(input(InkStrokeEventType::Down, 0, 0, 0), frame).ok());
    CHECK(engine.end(input(InkStrokeEventType::Up, 0.5, 0, 0.01), frame).ok());
    CHECK(!frame.contours.empty());
    CHECK(engine.begin(input(InkStrokeEventType::Down, 0, 0, 1), frame).ok());
    engine.cancel();
  }
  // Dense startup geometry remains the ordinary materialized sweep rather
  // than stale geometry from an earlier prefix.
  {
    InkEngine engine({.minWidth = 2.0, .maxWidth = 2.0, .smoothing = 0.0});
    engine.enableDiagnostics(true);
    InkStrokeFrame frame;
    CHECK(engine.begin(input(InkStrokeEventType::Down, 0, 0, 0), frame).ok());
    std::vector<InkStrokeInput> dense;
    for (int i = 1; i <= 70; ++i)
      dense.push_back(input(i == 70 ? InkStrokeEventType::Up : InkStrokeEventType::Move,
                            i * 0.02, 0, i * 0.01));
    CHECK(engine.endBatch(dense, frame).ok());
    CHECK(!engine.diagnosticSamples().empty());
    for (const auto& sample : engine.diagnosticSamples()) {
      CHECK(std::isfinite(sample.finalRadius));
    }
    CHECK(!frame.contours.empty());
    for (const auto& contour : frame.contours) {
      CHECK(contour.path.closed);
      CHECK(!contour.path.segments.empty());
    }
  }
  std::vector<InkStrokeInput> moves;
  moves.reserve(kMaxRealInputBatch);
  for (std::size_t index = 1; index <= kMaxRealInputBatch; ++index) {
    moves.push_back(input(InkStrokeEventType::Move, index * 1.5,
                          std::sin(index * 0.17) * 4.0, index * 0.01));
  }

  const InkStrokeFrame sequential = runStroke(1, moves);
  for (const std::size_t batchSize : {std::size_t{2}, std::size_t{4},
                                      std::size_t{8}, kMaxRealInputBatch}) {
    const InkStrokeFrame batched = runStroke(batchSize, moves);
    CHECK(same(batched.modeledPoints, sequential.modeledPoints));
    CHECK(same(batched.contours, sequential.contours));
    CHECK(batched.diagnostics.queuedRealInputCount ==
          sequential.diagnostics.queuedRealInputCount);
    CHECK(batched.diagnostics.stableModeledInputCount ==
          sequential.diagnostics.stableModeledInputCount);
  }

  InkEngine rollback;
  InkStrokeFrame frame;
  CHECK(rollback.begin(input(InkStrokeEventType::Down, 0.0, 0.0, 0.0), frame).ok());
  CHECK(rollback.update(input(InkStrokeEventType::Move, 2.0, 0.0, 0.1), frame).ok());
  const auto before = rollback.modeledPoints();
  const auto revision = frame.revision;
  const std::array invalidBatch{
      input(InkStrokeEventType::Move, 3.0, 0.0, 0.2),
      input(InkStrokeEventType::Move, 4.0, 0.0, 0.15),
  };
  CHECK(rollback.updateBatch(invalidBatch, frame).code ==
        InkStrokeStatusCode::TimeWentBackwards);
  CHECK(frame.revision == revision);
  CHECK(same(rollback.modeledPoints(), before));
  CHECK(rollback.update(input(InkStrokeEventType::Move, 5.0, 0.0, 0.3), frame).ok());

  InkEngine stylusRollback;
  CHECK(stylusRollback.begin(input(InkStrokeEventType::Down, 0.0, 0.0, 0.0), frame).ok());
  const std::array incompatibleStylusBatch{
      input(InkStrokeEventType::Move, 1.0, 0.0, 0.1),
      InkStrokeInput{.eventType = InkStrokeEventType::Move,
                  .position = {2.0, 0.0},
                  .time = 0.2,
                  .pressure = -1.0,
                  .tilt = -1.0,
                  .orientation = -1.0},
  };
  CHECK(stylusRollback.updateBatch(incompatibleStylusBatch, frame).code ==
        InkStrokeStatusCode::InvalidInput);
  CHECK(stylusRollback.modeledPoints().empty());

  InkEngine seamStylusRollback;
  CHECK(seamStylusRollback.begin(input(InkStrokeEventType::Down, 0.0, 0.0, 0.0),
                                 frame)
            .ok());
  CHECK(seamStylusRollback.update(input(InkStrokeEventType::Move, 1.0, 0.0, 0.1),
                                  frame)
            .ok());
  const auto seamBefore = seamStylusRollback.modeledPoints();
  const std::array seamChange{
      InkStrokeInput{.eventType = InkStrokeEventType::Move,
                  .position = {2.0, 0.0},
                  .time = 0.2,
                  .pressure = -1.0,
                  .tilt = -1.0,
                  .orientation = -1.0},
  };
  CHECK(seamStylusRollback.updateBatch(seamChange, frame).code ==
        InkStrokeStatusCode::InvalidInput);
  CHECK(same(seamStylusRollback.modeledPoints(), seamBefore));

  detail::CommittedCenterline centerline;
  detail::CommittedCenterlineUpdate centerlineUpdate;
  CHECK(centerline.begin(input(InkStrokeEventType::Down, 0.0, 0.0, 0.0),
                         centerlineUpdate)
            .ok());
  const std::array centerlineMoves{
      input(InkStrokeEventType::Move, 1.0, 0.0, 0.1),
      input(InkStrokeEventType::Move, 2.0, 0.0, 0.2),
      input(InkStrokeEventType::Move, 3.0, 0.0, 0.3),
  };
  CHECK(centerline.updateBatch(centerlineMoves, centerlineUpdate).ok());
  CHECK(centerline.points().size() == 4);
  CHECK(centerline.modeledInputs().back().rawSourceIndex == 3);
  const std::array duplicateBatch{
      input(InkStrokeEventType::Move, 4.0, 0.0, 0.4),
      input(InkStrokeEventType::Move, 4.0, 0.0, 0.4),
  };
  CHECK(centerline.updateBatch(duplicateBatch, centerlineUpdate).code ==
        detail::InputStatusCode::DuplicateInput);
  CHECK(centerline.points().size() == 4);

  InkEngine malformed;
  CHECK(malformed.begin(input(InkStrokeEventType::Down, 0.0, 0.0, 0.0), frame).ok());
  const std::array wrongOrder{
      input(InkStrokeEventType::Move, 1.0, 0.0, 0.1),
      input(InkStrokeEventType::Up, 2.0, 0.0, 0.2),
  };
  CHECK(malformed.updateBatch(wrongOrder, frame).code ==
        InkStrokeStatusCode::InvalidEvent);
  CHECK(malformed.modeledPoints().empty());
  CHECK(malformed.inProgress());
  return 0;
}
