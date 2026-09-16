#include "StrokeEngine.hpp"
#include "tests/support/TestSupport.hpp"

#include <cmath>
#include <cstddef>
#include <vector>

using namespace margelo::nitro::inksignpdf;

void checkSignatureBrushOwnership();

namespace {

StrokeInput input(StrokeEventType type, double x, double y, double time) {
  return {.eventType = type, .position = {x, y}, .time = time, .pressure = 0.5};
}

void checkWidthReplay(const std::vector<ModeledPoint>& actual,
                      const std::vector<ModeledPoint>& expected) {
  CHECK(actual.size() == expected.size());
  for (std::size_t index = 0; index < actual.size(); ++index) {
    CHECK(actual[index].point.x == expected[index].point.x);
    CHECK(actual[index].point.y == expected[index].point.y);
    CHECK(actual[index].time == expected[index].time);
    CHECK(actual[index].radius == expected[index].radius);
    CHECK(actual[index].acceleration.x == expected[index].acceleration.x);
    CHECK(actual[index].acceleration.y == expected[index].acceleration.y);
    CHECK(actual[index].pressure == expected[index].pressure);
  }
}

std::vector<StrokeInput> makeMoves(std::size_t count, double timeOffset = 0.0) {
  std::vector<StrokeInput> result;
  result.reserve(count + 1);
  result.push_back(input(StrokeEventType::Down, 0.0, 0.0, timeOffset));
  for (std::size_t index = 1; index <= count; ++index) {
    const double time = timeOffset +
        (index == 20 ? 19.0 / 120.0 : index / 120.0);
    const double x = index * 0.7;
    const double y = index < 32
        ? index * 0.2
        : index < 64 ? 6.4 - (index - 32) * 0.45
                     : 2.0 + std::sin(index * 0.09) * 18.0;
    result.push_back(input(StrokeEventType::Move, x, y, time));
  }
  return result;
}

void feedPrefix(StrokeEngine& engine, const std::vector<StrokeInput>& inputs,
                std::size_t lastIndex, StrokeFrame& frame) {
  CHECK(lastIndex < inputs.size());
  CHECK(engine.begin(inputs.front(), frame).ok());
  for (std::size_t index = 1; index <= lastIndex; ++index)
    CHECK(engine.update(inputs[index], frame).ok());
}

}  // namespace

int main() {
  checkSignatureBrushOwnership();
  const StrokeConfig config{.minWidth = 2.0,
                             .maxWidth = 4.0,
                             .logicalDisplayUnitsPerPageUnit = 1.0,
                             .smoothing = 0.4};
  const auto inputs = makeMoves(192);

  StrokeEngine incremental(config);
  StrokeFrame frame;
  CHECK(incremental.begin(inputs.front(), frame).ok());
  StrokeWorkStats previousStats = incremental.workStats();
  bool sawReplacement = false;

  for (std::size_t index = 1; index < inputs.size(); ++index) {
    CHECK(incremental.update(inputs[index], frame).ok());
    if (frame.modeledPointStart > 0 &&
        frame.modeledPointStart < incremental.modeledPoints().size())
      sawReplacement = true;

    const StrokeWorkStats currentStats = incremental.workStats();
    CHECK(currentStats.widthPointsProcessed >=
          previousStats.widthPointsProcessed);
    CHECK(currentStats.widthPointsProcessed -
              previousStats.widthPointsProcessed <= 16);
    previousStats = currentStats;

    StrokeEngine replay(config);
    StrokeFrame replayFrame;
    feedPrefix(replay, inputs, index, replayFrame);
    checkWidthReplay(incremental.modeledPoints(), replay.modeledPoints());
  }

  CHECK(sawReplacement);
  CHECK(incremental.workStats().widthPointsProcessed <
        incremental.modeledPoints().size() * 16);

  StrokeEngine reference(config);
  StrokeFrame referenceFrame;
  feedPrefix(reference, inputs, inputs.size() - 1, referenceFrame);
  const StrokeInput endInput = input(
      StrokeEventType::Up, inputs.back().position.x, inputs.back().position.y,
      193.0 / 120.0);
  CHECK(incremental.end(endInput, frame).ok());
  CHECK(reference.end(endInput, referenceFrame).ok());
  checkWidthReplay(frame.modeledPoints, referenceFrame.modeledPoints);

  StrokeEngine predicted(config);
  StrokeEngine predictionReference(config);
  predicted.enableDiagnostics(true);
  predictionReference.enableDiagnostics(true);
  StrokeFrame predictedFrame;
  StrokeFrame predictionReferenceFrame;
  feedPrefix(predicted, inputs, 48, predictedFrame);
  feedPrefix(predictionReference, inputs, 48, predictionReferenceFrame);
  const auto beforePrediction = predicted.modeledPoints();
  const auto beforePredictionDiagnostics = predicted.diagnosticSamples();
  const StrokeWorkStats beforePredictionStats = predicted.workStats();
  StrokePredictionFrame prediction;
  const std::vector<StrokeInput> predictedInputs{
      input(StrokeEventType::Move, 35.0, 14.0, 50.0 / 120.0),
      input(StrokeEventType::Move, 36.0, 15.0, 51.0 / 120.0)};
  CHECK(predicted.replacePredictedInputs(predictedInputs, 52.0 / 120.0,
                                         prediction).ok());
  checkWidthReplay(predicted.modeledPoints(), beforePrediction);
  CHECK(predicted.diagnosticSamples().size() >=
        beforePredictionDiagnostics.size());
  for (std::size_t index = 0; index < beforePredictionDiagnostics.size(); ++index) {
    CHECK(predicted.diagnosticSamples()[index].modeledSourceIndex ==
          beforePredictionDiagnostics[index].modeledSourceIndex);
    CHECK(predicted.diagnosticSamples()[index].radius ==
          beforePredictionDiagnostics[index].radius);
    CHECK(predicted.diagnosticSamples()[index].dtSeconds ==
          beforePredictionDiagnostics[index].dtSeconds);
    CHECK(predicted.diagnosticSamples()[index].turnFactor ==
          beforePredictionDiagnostics[index].turnFactor);
    CHECK(predicted.diagnosticSamples()[index].effectiveSpeedDisplay ==
          beforePredictionDiagnostics[index].effectiveSpeedDisplay);
    CHECK(predicted.diagnosticSamples()[index].responseDistancePage ==
          beforePredictionDiagnostics[index].responseDistancePage);
  }
  CHECK(predicted.workStats().widthPointsProcessed ==
        beforePredictionStats.widthPointsProcessed);

  // Centerline prediction states are converted back to the same absolute
  // clock used by real modeled states. A nonzero stroke origin must therefore
  // produce identical width recurrence values, not a second time offset.
  const StrokeConfig clockConfig{.minWidth = 2.0,
                                 .maxWidth = 4.0,
                                 .logicalDisplayUnitsPerPageUnit = 1.0,
                                 .smoothing = 0.0};
  StrokeEngine clock(clockConfig);
  StrokeEngine shifted(clockConfig);
  clock.enableDiagnostics(true);
  shifted.enableDiagnostics(true);
  StrokeFrame clockFrame;
  StrokeFrame shiftedFrame;
  const auto clockInputs = makeMoves(4);
  const auto shiftedInputs = makeMoves(4, 12.0);
  feedPrefix(clock, clockInputs, 4, clockFrame);
  feedPrefix(shifted, shiftedInputs, 4, shiftedFrame);
  StrokePredictionFrame clockPrediction;
  StrokePredictionFrame shiftedPrediction;
  const std::vector<StrokeInput> clockPredictedInputs{
      input(StrokeEventType::Move, 35.0, 14.0, 50.0 / 120.0),
      input(StrokeEventType::Move, 36.0, 15.0, 51.0 / 120.0)};
  const std::vector<StrokeInput> shiftedPredictedInputs{
      input(StrokeEventType::Move, 35.0, 14.0, 12.0 + 50.0 / 120.0),
      input(StrokeEventType::Move, 36.0, 15.0, 12.0 + 51.0 / 120.0)};
  CHECK(clock.replacePredictedInputs(clockPredictedInputs, 52.0 / 120.0,
                                     clockPrediction).ok());
  CHECK(shifted.replacePredictedInputs(
            shiftedPredictedInputs, 12.0 + 52.0 / 120.0,
            shiftedPrediction).ok());
  CHECK(shifted.diagnosticSamples().size() == clock.diagnosticSamples().size());
  for (std::size_t index = 0; index < clock.diagnosticSamples().size();
       ++index) {
    const auto& original = clock.diagnosticSamples()[index];
    const auto& shiftedSample = shifted.diagnosticSamples()[index];
    CHECK(std::abs(shiftedSample.time - (original.time + 12.0)) < 1e-12);
    CHECK(std::abs(shiftedSample.radius - original.radius) < 1e-9);
    CHECK(std::abs(shiftedSample.targetRadius - original.targetRadius) < 1e-9);
    CHECK(std::abs(shiftedSample.dtSeconds - original.dtSeconds) < 1e-12);
    CHECK(std::abs(shiftedSample.turnFactor - original.turnFactor) < 1e-9);
    CHECK(std::abs(shiftedSample.effectiveSpeedDisplay -
                  original.effectiveSpeedDisplay) < 1e-9);
    CHECK(std::abs(shiftedSample.responseDistancePage -
                  original.responseDistancePage) < 1e-9);
    CHECK(std::abs(shiftedSample.responseAlpha - original.responseAlpha) < 1e-9);
  }

  CHECK(predicted.update(inputs[49], predictedFrame).ok());
  CHECK(predictionReference.update(inputs[49], predictionReferenceFrame).ok());
  checkWidthReplay(predicted.modeledPoints(),
                   predictionReference.modeledPoints());

  predicted.cancel();
  StrokeFrame resetFrame;
  CHECK(predicted.begin(inputs.front(), resetFrame).ok());
  CHECK(predicted.update(inputs[1], resetFrame).ok());
  StrokeEngine resetReference(config);
  StrokeFrame resetReferenceFrame;
  CHECK(resetReference.begin(inputs.front(), resetReferenceFrame).ok());
  CHECK(resetReference.update(inputs[1], resetReferenceFrame).ok());
  checkWidthReplay(predicted.modeledPoints(),
                   resetReference.modeledPoints());

  return 0;
}
