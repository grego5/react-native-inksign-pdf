#include "StrokeEngine.hpp"
#include "modeling/SignatureStrokeStyle.hpp"
#include "modeling/VelocityWidthModel.hpp"
#include "tests/support/TestSupport.hpp"

#include <cmath>
#include <algorithm>
#include <array>
#include <limits>
#include <span>
#include <stdexcept>
#include <vector>

using namespace margelo::nitro::inksignpdf;
using namespace margelo::nitro::inksignpdf::detail;
using StrokeContourCollection = margelo::nitro::inksignpdf::StrokeContourCollection;
using StrokeContour = margelo::nitro::inksignpdf::StrokeContour;

namespace {

StrokeInput input(StrokeEventType type, double x, double y, double time) {
  return {.eventType = type, .position = {x, y}, .time = time, .pressure = 0.5};
}

bool same(Vec2 a, Vec2 b) { return a.x == b.x && a.y == b.y; }
bool same(const StrokeContour& a, const StrokeContour& b) {
  if (a.sourceStart != b.sourceStart || a.sourceEnd != b.sourceEnd ||
      a.path.closed != b.path.closed ||
      a.path.segments.size() != b.path.segments.size()) return false;
  for (std::size_t i = 0; i < a.path.segments.size(); ++i) {
    const auto& x = a.path.segments[i];
    const auto& y = b.path.segments[i];
    if (!same(x.p0, y.p0) || !same(x.c1, y.c1) || !same(x.c2, y.c2) ||
        !same(x.p3, y.p3) || x.sourceStart != y.sourceStart ||
        x.sourceEnd != y.sourceEnd) return false;
  }
  return true;
}
bool same(const StrokeContourCollection& a,
          const StrokeContourCollection& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (!same(a[i], b[i])) return false;
  return true;
}

std::size_t taperSuffixCount(const std::vector<ModeledPoint>& points,
                             double maximumDistance) {
  std::size_t start = points.size();
  double remaining = 0.0;
  for (std::size_t index = points.size(); index-- > 0;) {
    if (remaining <= maximumDistance) start = index;
    if (index > 0) remaining += points[index].distance;
  }
  return points.size() - start;
}

struct Renderer {
  StrokeContourCollection contours;

  void apply(const StrokeFrame& frame) {
    contours = frame.contours;
  }
};

std::vector<StrokeFrame> captureRealFrames(
    const StrokeConfig& config, const std::vector<StrokeInput>& inputs,
    bool reuseOutput) {
  StrokeEngine engine(config);
  std::vector<StrokeFrame> result;
  result.reserve(inputs.size() - 1);
  StrokeFrame reused;
  CHECK(engine.begin(inputs.front(), reused).ok());
  for (std::size_t index = 1; index < inputs.size(); ++index) {
    if (reuseOutput) {
      CHECK(engine.update(inputs[index], reused).ok());
      result.push_back(reused);
    } else {
      StrokeFrame fresh;
      CHECK(engine.update(inputs[index], fresh).ok());
      result.push_back(fresh);
    }
  }
  return result;
}

void checkContours(const StrokeContourCollection& contours) {
  for (const auto& contour : contours) {
    CHECK(contour.path.closed);
    CHECK(!contour.path.segments.empty());
    for (std::size_t i = 0; i < contour.path.segments.size(); ++i) {
      const auto& segment = contour.path.segments[i];
      const auto& next = contour.path.segments[(i + 1) % contour.path.segments.size()];
      CHECK(same(segment.p3, next.p0));
      for (const Vec2 point : {segment.p0, segment.c1, segment.c2, segment.p3}) {
        CHECK(std::isfinite(point.x));
        CHECK(std::isfinite(point.y));
      }
    }
  }
}

}  // namespace

int main() {
  StrokeConfig config;
  config.smoothing = 0.0;
  for (const StrokeConfig invalid : {
           StrokeConfig{.minWidth = 0.0},
           StrokeConfig{.minWidth = 8.0, .maxWidth = 2.0},
           StrokeConfig{.smoothing = -0.1}, StrokeConfig{.smoothing = 1.1},
           StrokeConfig{.logicalDisplayUnitsPerPageUnit = 0.0},
           StrokeConfig{.logicalDisplayUnitsPerPageUnit =
                            std::numeric_limits<double>::quiet_NaN()}}) {
    bool threw = false;
    try { StrokeEngine invalidEngine(invalid); }
    catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw);
  }

  StrokeEngine engine(config);
  StrokeFrame frame;
  const StrokeConfig originalConfig = engine.config();
  StrokeConfig invalidConfig = originalConfig;
  invalidConfig.maxWidth = 0.0;
  CHECK(engine.setConfig(invalidConfig).code == StrokeStatusCode::InvalidInput);
  CHECK(engine.update(input(StrokeEventType::Move, 1, 1, 0), frame).code ==
        StrokeStatusCode::NotInProgress);
  CHECK(engine.begin(input(StrokeEventType::Down, 0, 0, 0), frame).ok());
  CHECK(frame.contours.empty());
  CHECK(engine.setConfig(config).code == StrokeStatusCode::ReconfigureWhileInProgress);

  detail::SignatureStrokeStyle widthStyle(1.0, 2.0);
  CHECK(widthStyle.logicalDisplayUnitsPerPageUnit() == 1.0);

  VelocityWidthModel widthModel(widthStyle);
  const auto start = widthModel.begin(
      {.eventType = StrokeEventType::Down, .position = {0.0, 0.0}, .time = 0.0},
      {1200.0, 0.0});
  CHECK(start.radius == widthStyle.minimumRadius());
  CHECK(start.responseAlpha == 0.0);
  CHECK(start.dtSeconds == 0.0);
  CHECK(start.turnFactor == 1.0);
  CHECK(start.effectiveSpeedDisplay == 1200.0);
  const auto oneDistance = widthModel.update(
      {.eventType = StrokeEventType::Move, .position = {8.0, 0.0}, .time = 0.1},
      {1200.0, 0.0});
  CHECK(oneDistance.segmentDistance == 8.0);
  CHECK(oneDistance.responseDistancePage == widthStyle.responseDistancePage());
  CHECK(std::abs(oneDistance.responseAlpha -
                 (-std::expm1(-8.0 / widthStyle.responseDistancePage()))) <
        1e-12);
  CHECK(oneDistance.radius >= widthStyle.minimumRadius());
  CHECK(oneDistance.radius <= widthStyle.maximumRadius());
  const auto zeroDistance = widthModel.update(
      {.eventType = StrokeEventType::Move, .position = {8.0, 0.0}, .time = 0.2},
      {0.0, 0.0});
  CHECK(zeroDistance.radius == oneDistance.radius);
  CHECK(zeroDistance.segmentDistance == 0.0);
  CHECK(zeroDistance.responseDistancePage == widthStyle.responseDistancePage(true));
  CHECK(zeroDistance.responseAlpha == 0.0);

  detail::SignatureStrokeStyle fixedStyle(0.0, 0.0);
  VelocityWidthModel fixedModel(fixedStyle);
  CHECK(fixedModel.begin(
            {.eventType = StrokeEventType::Down, .position = {}, .time = 0.0},
            {1200.0, 0.0}).radius == 0.0);
  CHECK(fixedModel.update(
            {.eventType = StrokeEventType::Move, .position = {100.0, 2.0}, .time = 0.0},
            {0.0, 0.0}).radius == 0.0);

  StrokeEngine accelerating(config);
  accelerating.enableDiagnostics(true);
  StrokeFrame acceleratingFrame;
  CHECK(accelerating.begin(input(StrokeEventType::Down, 0.0, 0.0, 0.0),
                           acceleratingFrame).ok());
  for (const auto& move : {input(StrokeEventType::Move, 1.0, 0.0, 0.01),
                           input(StrokeEventType::Move, 2.0, 0.0, 0.02),
                           input(StrokeEventType::Move, 4.0, 0.0, 0.03),
                           input(StrokeEventType::Move, 8.0, 0.0, 0.04),
                           input(StrokeEventType::Move, 20.0, 0.0, 0.05)})
    CHECK(accelerating.update(move, acceleratingFrame).ok());
  const auto& acceleratingSamples = accelerating.diagnosticSamples();
  CHECK(!acceleratingSamples.empty());
  for (const auto& sample : acceleratingSamples) {
    CHECK(std::isfinite(sample.targetRadius));
    CHECK(std::isfinite(sample.radius));
    CHECK(std::isfinite(sample.finalRadius));
    CHECK(std::isfinite(sample.dtSeconds));
    CHECK(std::isfinite(sample.turnFactor));
    CHECK(std::isfinite(sample.effectiveSpeedDisplay));
    CHECK(std::isfinite(sample.responseDistancePage));
    CHECK(sample.turnFactor >= 0.0 && sample.turnFactor <= 1.0);
    CHECK(sample.radius >= config.minWidth * 0.5);
    CHECK(sample.radius <= config.maxWidth * 0.5);
    CHECK(sample.responseAlpha >= 0.0 && sample.responseAlpha <= 1.0);
  }
  accelerating.cancel();

  Renderer renderer;
  const std::vector<StrokeInput> trace{
      input(StrokeEventType::Move, 2, 0, 0.1), input(StrokeEventType::Move, 4, 1, 0.2),
      input(StrokeEventType::Move, 5, 3, 0.3), input(StrokeEventType::Move, 4, 5, 0.4),
      input(StrokeEventType::Move, 2, 6, 0.5)};
  for (const auto& value : trace) {
    CHECK(engine.update(value, frame).ok());
    renderer.apply(frame);
  }
  CHECK(!renderer.contours.empty());

  std::vector<StrokeInput> captureTrace;
  captureTrace.reserve(trace.size() + 1);
  captureTrace.push_back(input(StrokeEventType::Down, 0, 0, 0));
  captureTrace.insert(captureTrace.end(), trace.begin(), trace.end());
  const auto reusedFrames = captureRealFrames(config, captureTrace, true);
  const auto freshFrames = captureRealFrames(config, captureTrace, false);
  CHECK(reusedFrames.size() == freshFrames.size());
  for (std::size_t index = 0; index < reusedFrames.size(); ++index) {
    CHECK(reusedFrames[index].revision == freshFrames[index].revision);
    CHECK(reusedFrames[index].committedPointCount ==
          freshFrames[index].committedPointCount);
    CHECK(same(reusedFrames[index].contours, freshFrames[index].contours));
  }

  StrokePredictionFrame prediction;
  const auto beforePrediction = engine.modeledPoints();
  const std::vector<StrokeInput> predicted{
      input(StrokeEventType::Move, 1, 7, 0.6), input(StrokeEventType::Move, 0, 7, 0.7)};
  CHECK(engine.replacePredictedInputs(predicted, 0.8, prediction).ok());
  CHECK(!prediction.contours.empty());
  CHECK(engine.modeledPoints().size() == beforePrediction.size());
  for (std::size_t i = 0; i < beforePrediction.size(); ++i)
    CHECK(same(engine.modeledPoints()[i].point, beforePrediction[i].point));

  CHECK(engine.update(input(StrokeEventType::Move, 2, 6, 0.5), frame).code ==
        StrokeStatusCode::DuplicateInput);
  const auto movingRevisionBeforeEnd = frame.revision;
  CHECK(engine.end(input(StrokeEventType::Up, 0, 7, 0.9), frame).ok());
  CHECK(frame.isFinal());
  CHECK(frame.revision == movingRevisionBeforeEnd + 1);
  CHECK(frame.modeledPointStart == 0);
  CHECK(frame.committedPointCount == frame.modeledPoints.size());
  CHECK(!frame.modeledPoints.empty());
  CHECK(!frame.contours.empty());
  checkContours(frame.contours);

  StrokeEngine repeated(config);
  StrokeFrame repeatedFrame;
  CHECK(repeated.begin(input(StrokeEventType::Down, 0, 0, 0), repeatedFrame).ok());
  for (const auto& value : trace) CHECK(repeated.update(value, repeatedFrame).ok());
  CHECK(repeated.end(input(StrokeEventType::Up, 0, 7, 0.9), repeatedFrame).ok());
  CHECK(same(frame.contours, repeatedFrame.contours));

  StrokeConfig denseConfig = config;
  denseConfig.minWidth = 0.5;
  denseConfig.maxWidth = 0.5;
  denseConfig.smoothing = 0.4;
  StrokeEngine dense(denseConfig);
  StrokeFrame denseFrame;
  Renderer denseRenderer;
  CHECK(dense.begin(input(StrokeEventType::Down, 0.0, 0.0, 0.0), denseFrame).ok());
  constexpr int denseSampleCount = 220;
  for (int index = 1; index <= denseSampleCount; ++index) {
    const double x = index <= 160 ? index : 160.0 - (index - 160) * 0.75;
    CHECK(dense.update(input(StrokeEventType::Move, x, 0.0,
                            index / 180.0), denseFrame).ok());
    denseRenderer.apply(denseFrame);
    CHECK(!denseRenderer.contours.empty());
  }
  CHECK(taperSuffixCount(dense.modeledPoints(), 80.0) > 0);
  const double denseEnd = 160.0 - (denseSampleCount - 160) * 0.75;
  CHECK(dense.end(input(StrokeEventType::Up, denseEnd, 0.0,
                       (denseSampleCount + 1.0) / 180.0), denseFrame).ok());
  CHECK(!denseFrame.contours.empty());

  StrokeEngine tap(config);
  StrokeFrame tapFrame;
  CHECK(tap.begin(input(StrokeEventType::Down, 12.0, 8.0, 1.0), tapFrame).ok());
  CHECK(tapFrame.revision == 0);
  CHECK(tap.end(input(StrokeEventType::Up, 12.0, 8.0, 1.4), tapFrame).ok());
  CHECK(tapFrame.isFinal());
  CHECK(tapFrame.revision == 1);
  CHECK(tapFrame.modeledPointStart == 0);
  CHECK(tapFrame.committedPointCount == 1);
  CHECK(tapFrame.modeledPoints.size() == 1);
  CHECK(tapFrame.contours.size() == 1);
  CHECK(tapFrame.contours.front().path.closed);
  CHECK(tapFrame.contours.front().path.segments.size() >= 4);

  StrokeConfig headConfig = config;
  headConfig.smoothing = 0.0;
  StrokeEngine head(headConfig);
  StrokeFrame headFrame;
  Renderer headRenderer;
  CHECK(head.begin(input(StrokeEventType::Down, 0.0, 0.0, 0.0),
                   headFrame)
            .ok());
  detail::SignatureStrokeStyle headStyle(1.0, 2.0);
  for (int index = 1; index <= 240; ++index) {
    CHECK(head.update(input(StrokeEventType::Move, index * 0.5, 0.0,
                            index / 60.0),
                      headFrame)
              .ok());
    headRenderer.apply(headFrame);
    CHECK(!head.modeledPoints().empty());
    CHECK(head.modeledPoints().front().radius ==
          headStyle.minimumRadius());
    checkContours(headFrame.contours);
  }

  StrokeEngine shortMoved(headConfig);
  StrokeFrame shortFrame;
  CHECK(shortMoved.begin(input(StrokeEventType::Down, 4.0, 3.0, 0.0),
                         shortFrame)
            .ok());
  CHECK(shortMoved.update(input(StrokeEventType::Move, 5.0, 3.0, 0.1),
                          shortFrame)
            .ok());
  CHECK(shortMoved.end(input(StrokeEventType::Up, 5.0, 3.0, 0.2),
                       shortFrame)
            .ok());
  CHECK(shortFrame.isFinal());
  CHECK(shortFrame.modeledPoints.front().radius ==
        headStyle.minimumRadius());
  CHECK(!shortFrame.contours.empty());
  CHECK(shortFrame.contours.front().path.closed);

  engine.cancel();
  CHECK(!engine.inProgress());
  CHECK(engine.modeledPoints().empty());

  StrokeEngine observable(config);
  StrokeFrame observableFrame;
  CHECK(observable.begin(input(StrokeEventType::Down, 0.0, 0.0, 0.0),
                         observableFrame).ok());
  CHECK(observable.update(input(StrokeEventType::Move, 10.0, 0.0, 0.1),
                          observableFrame).ok());
  CHECK(observable.diagnosticSamples().empty());
  observable.cancel();
  observable.enableDiagnostics(true);
  CHECK(observable.begin(input(StrokeEventType::Down, 0.0, 0.0, 0.0),
                         observableFrame).ok());
  CHECK(observable.update(input(StrokeEventType::Move, 10.0, 0.0, 0.1),
                          observableFrame).ok());
  CHECK(!observable.diagnosticSamples().empty());
  CHECK(observable.diagnosticSamples().front().real);
  StrokePredictionFrame observablePrediction;
  CHECK(observable.replacePredictedInputs(
      std::span<const StrokeInput>(
          std::array{input(StrokeEventType::Move, 20.0, 0.0, 0.2)}),
      0.3, observablePrediction).ok());
  CHECK(std::any_of(observable.diagnosticSamples().begin(),
                    observable.diagnosticSamples().end(),
                    [](const auto& sample) { return sample.predicted; }));
  observable.cancel();
  return 0;
}
