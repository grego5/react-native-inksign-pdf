#include "input/CurrentInkInputModeler.hpp"

#include "ink-engine/tests/support/TestSupport.hpp"

#include <cmath>
#include <vector>

using namespace margelo::nitro::inksignpdf::detail;

namespace {

CurrentInkRawInput raw(double time, double x, double pressure = -1.0,
                       double tilt = -1.0, double orientation = -1.0) {
  return {.position = {x, 0.0},
          .elapsedTime = time,
          .pressure = pressure,
          .tilt = tilt,
          .orientation = orientation};
}

CurrentInkRawInput raw2(double time, double x, double y) {
  return {.position = {x, y}, .elapsedTime = time};
}

bool near(double first, double second) {
  return std::abs(first - second) <= 1.0e-9;
}

}  // namespace

int main() {
  // Passthrough owns real input, replaces prediction, and reports elapsed time
  // through the complete modeled range even when prediction is in the future.
  CurrentInkInputModeler passthrough;
  passthrough.start();
  const std::vector<CurrentInkRawInput> down = {raw(0.0, 0.0, 0.2, 0.1, 0.2)};
  passthrough.extend(down, 0.0, false);
  const std::vector<CurrentInkRawInput> move = {raw(0.01, 10.0, 0.6, 0.3, 0.4)};

  // Smoothing is a centered temporal window. Zero is an exact passthrough;
  // one uses the full 25 ms window, clamped at the stroke endpoint.
  CurrentInkInputModeler smoothed(1.0);
  smoothed.start();
  smoothed.extend(down, 0.0, false);
  smoothed.extend(move, 0.01, false);
  CHECK(smoothed.modeledInputs()[0].state.position.x == 0.0);
  CHECK(smoothed.modeledInputs().size() == 3);
  CHECK(smoothed.modeledInputs()[1].state.position.x == 5.0);
  CHECK(smoothed.modeledInputs().back().state.position.x == 10.0);

  const std::vector<CurrentInkRawInput> predicted = {
      raw(0.02, 20.0, 0.7, 0.4, 0.5), raw(0.03, 30.0, 0.8, 0.5, 0.6)};
  CurrentInkInputModeler predictionWorkspace;
  passthrough.extend(move, 0.01, false);
  CHECK(passthrough.state().stableInputCount == 1);
  CHECK(passthrough.state().realInputCount == 2);
  CHECK(passthrough.lastRealMovingVelocity().x == 1000.0);
  CHECK(passthrough.modeledInputs().size() == 2);
  CHECK(passthrough.state().completeElapsedTime == 0.01);
  CHECK(!passthrough.modeledInputs().back().predicted);
  CHECK(passthrough.modeledInputs()[1].state.velocity.x == 1000.0);
  CHECK(passthrough.modeledInputs()[0].state.acceleration.x == 0.0);
  CHECK(passthrough.modeledInputs()[1].state.acceleration.x == 100000.0);

  std::vector<CurrentInkModeledInput> predictedSuffix;
  passthrough.predictionSuffix(predicted, 0.015, predictedSuffix,
                               predictionWorkspace);
  CHECK(predictedSuffix.size() == 2);
  CHECK(predictedSuffix.back().predicted);
  CHECK(predictedSuffix[0].state.velocity.x == 1000.0);
  CHECK(std::isfinite(predictedSuffix[0].state.acceleration.x));
  CHECK(passthrough.modeledInputs().size() == 2);
  CHECK(passthrough.state().completeElapsedTime == 0.01);

  const std::vector<CurrentInkRawInput> replacement = {raw(0.02, 12.0)};
  passthrough.predictionSuffix(replacement, 0.02, predictedSuffix,
                               predictionWorkspace);
  CHECK(predictedSuffix.size() == 1);
  CHECK(predictedSuffix.back().state.position.x == 12.0);
  CHECK(predictedSuffix.back().predicted);

  const std::vector<CurrentInkRawInput> finalMove = {raw(0.04, 40.0)};
  passthrough.extend(finalMove, 0.04, true);
  CHECK(passthrough.state().stableInputCount ==
        passthrough.state().realInputCount);
  CHECK(passthrough.state().realInputCount ==
        passthrough.modeledInputs().size());
  CHECK(!passthrough.modeledInputs().back().predicted);
  CHECK(passthrough.modeledInputs().back().state.position.x == 40.0);
  CHECK(std::isfinite(passthrough.modeledInputs().back().state.velocity.x));
  CHECK(passthrough.lastRealMovingVelocity().x ==
        passthrough.modeledInputs().back().state.velocity.x);
  const double movingVelocity = passthrough.lastRealMovingVelocity().x;
  const std::vector<CurrentInkRawInput> stationaryTerminal = {
      raw(0.05, 40.0)};
  passthrough.extend(stationaryTerminal, 0.05, true);
  CHECK(passthrough.lastRealMovingVelocity().x == movingVelocity);
  CHECK(passthrough.modeledInputs().back().state.velocity.x == movingVelocity);

  // Zero smoothing is exact passthrough: it does not synthesize intermediate
  // positions, but still supplies the ordinary finite-difference velocity.
  CurrentInkInputModeler exact(0.0);
  exact.start();
  const std::vector<CurrentInkRawInput> exactInputs = {
      raw2(0.0, 0.0, 0.0), raw2(0.02, 3.0, 4.0)};
  exact.extend(exactInputs, 0.02, true);
  CHECK(exact.modeledInputs().size() == 2);
  CHECK(exact.modeledInputs()[1].state.position.x == 3.0);
  CHECK(exact.modeledInputs()[1].state.position.y == 4.0);
  CHECK(exact.modeledInputs()[1].state.velocity.x == 150.0);
  CHECK(exact.modeledInputs()[1].state.velocity.y == 200.0);
  CHECK(exact.modeledInputs()[0].state.acceleration.x == 0.0);
  CHECK(exact.modeledInputs()[0].state.acceleration.y == 0.0);
  CHECK(exact.modeledInputs()[1].state.acceleration.x == 7500.0);
  CHECK(exact.modeledInputs()[1].state.acceleration.y == 10000.0);
  CHECK(forwardAcceleration({3.0, 4.0}, {7500.0, 10000.0}) == 12500.0);
  CHECK(std::abs(lateralAcceleration({3.0, 4.0}, {7500.0, 10000.0})) <=
        1.0e-9);
  CHECK(forwardAcceleration({}, {1.0, 2.0}) == 0.0);
  CHECK(lateralAcceleration({}, {1.0, 2.0}) == 0.0);

  CurrentInkInputModeler constantVelocity(0.4);
  constantVelocity.start();
  std::vector<CurrentInkRawInput> constantInputs;
  for (int index = 0; index < 20; ++index)
    constantInputs.push_back(raw2(index * 0.01, index * 10.0, 0.0));
  constantVelocity.extend(constantInputs, 0.19, true);
  CHECK(constantVelocity.modeledInputs().size() >= constantInputs.size());
  for (const auto& modeled : constantVelocity.modeledInputs()) {
    CHECK(std::isfinite(modeled.state.acceleration.x));
    CHECK(std::isfinite(modeled.state.acceleration.y));
    CHECK(std::abs(modeled.state.acceleration.x) <= 1.0e-6);
    CHECK(std::abs(modeled.state.acceleration.y) <= 1.0e-6);
  }

  // Smoothing 0.4 maps to a 10 ms full window. The centered average around
  // the middle of this V is (7.5, 0), while the terminal contact is exact.
  CurrentInkInputModeler tenMilliseconds(0.4);
  tenMilliseconds.start();
  const std::vector<CurrentInkRawInput> corner = {
      raw2(0.0, 0.0, 0.0), raw2(0.01, 10.0, 0.0),
      raw2(0.02, 0.0, 0.0)};
  tenMilliseconds.extend(corner, 0.02, true);
  CHECK(tenMilliseconds.modeledInputs().size() == 5);
  CHECK(tenMilliseconds.modeledInputs()[2].state.position.x == 7.5);
  CHECK(tenMilliseconds.modeledInputs()[2].state.position.y == 0.0);
  CHECK(tenMilliseconds.modeledInputs().back().state.position.x == 0.0);
  CHECK(tenMilliseconds.modeledInputs().back().state.position.y == 0.0);

  // Upsampling uses at most 180 Hz spacing and keeps sparse curves smooth
  // without changing the raw endpoints.
  CurrentInkInputModeler upsampled(0.4);
  upsampled.start();
  const std::vector<CurrentInkRawInput> sparseCorner = {
      raw2(0.0, 0.0, 0.0), raw2(0.01, 100.0, 0.0),
      raw2(0.02, 100.0, 100.0)};
  upsampled.extend(sparseCorner, 0.02, true);
  CHECK(upsampled.modeledInputs().size() == 5);
  CHECK(near(upsampled.modeledInputs()[2].state.position.x, 87.5));
  CHECK(near(upsampled.modeledInputs()[2].state.position.y, 12.5));
  CHECK(upsampled.modeledInputs().back().state.position.x == 100.0);
  CHECK(upsampled.modeledInputs().back().state.position.y == 100.0);

  // Epsilon filtering removes stationary modeled duplicates, while a small
  // terminal displacement remains exact for the latest raw contact.
  CurrentInkInputModeler epsilon(0.4);
  epsilon.start();
  const std::vector<CurrentInkRawInput> stationary = {
      raw2(0.0, 12.0, 34.0), raw2(0.1, 12.0, 34.0),
      raw2(0.2, 12.0, 34.0)};
  epsilon.extend(stationary, 0.2, true);
  CHECK(epsilon.modeledInputs().size() == 1);
  CHECK(epsilon.state().realInputCount == 1);

  // Equal-time samples are accepted and do not create an infinite velocity;
  // the final later contact remains authoritative.
  CurrentInkInputModeler equalTime(0.4);
  equalTime.start();
  const std::vector<CurrentInkRawInput> equalTimeInputs = {
      raw2(0.0, 0.0, 0.0), raw2(0.0, 3.0, 4.0),
      raw2(0.02, 10.0, 0.0)};
  equalTime.extend(equalTimeInputs, 0.02, true);
  CHECK(equalTime.modeledInputs().back().state.position.x == 10.0);
  CHECK(equalTime.modeledInputs().back().state.position.y == 0.0);
  for (const auto& modeled : equalTime.modeledInputs()) {
    CHECK(std::isfinite(modeled.state.velocity.x));
    CHECK(std::isfinite(modeled.state.velocity.y));
  }

  // Finish marks the real modeled range stable without a separate finish-time
  // smoothing pass, and preserves exact final contact.
  CurrentInkInputModeler finish;
  finish.start();
  const std::vector<CurrentInkRawInput> finishInputs = {
      raw2(0.0, 0.0, 0.0), raw2(0.02, 20.0, 0.0)};
  finish.extend(finishInputs, 0.02, false);
  CHECK(finish.modeledInputs().back().state.position.x == 20.0);
  finish.extend({}, 0.02, true);
  CHECK(finish.state().stableInputCount == finish.state().realInputCount);
  CHECK(finish.modeledInputs().back().state.position.x == 20.0);

  CurrentInkInputModeler provenance(0.4);
  provenance.start();
  const std::vector<CurrentInkRawInput> provenanceDown{
      {.position = {0.0, 0.0}, .elapsedTime = 0.0, .rawSourceIndex = 0}};
  const std::vector<CurrentInkRawInput> provenanceMove{
      {.position = {10.0, 0.0}, .elapsedTime = 0.02, .rawSourceIndex = 1}};
  provenance.extend(provenanceDown, 0.0, false);
  provenance.extend(provenanceMove, 0.02, true);
  CHECK(provenance.modeledInputs().size() >= 2);
  for (std::size_t index = 1; index < provenance.modeledInputs().size(); ++index) {
    CHECK(provenance.modeledInputs()[index].rawSourceIndex >=
          provenance.modeledInputs()[index - 1].rawSourceIndex);
    CHECK(provenance.modeledInputs()[index].modeledSourceIndex >
          provenance.modeledInputs()[index - 1].modeledSourceIndex);
    CHECK(provenance.modeledInputs()[index].state.rawSourceIndex ==
          provenance.modeledInputs()[index].rawSourceIndex);
    CHECK(provenance.modeledInputs()[index].state.modeledSourceIndex ==
          provenance.modeledInputs()[index].modeledSourceIndex);
  }

  // Real updates replay only the centered smoothing window, not the complete
  // stroke prefix. Doubling a long stroke must therefore approximately double
  // model evaluation work rather than quadruple it.
  auto incrementalWork = [](int count) {
    CurrentInkInputModeler modeler(0.4);
    modeler.start();
    for (int index = 0; index < count; ++index) {
      const CurrentInkRawInput input =
          raw2(index / 120.0, index * 0.4, std::sin(index * 0.025));
      modeler.extend(std::span<const CurrentInkRawInput>(&input, 1),
                     input.elapsedTime, false);
    }
    return modeler.modeledSamplesEvaluated();
  };
  const auto work256 = incrementalWork(256);
  const auto work512 = incrementalWork(512);
  CHECK(work512 < work256 * 3);

  for (const std::size_t batchSize : {std::size_t{1}, std::size_t{2},
                                      std::size_t{4}, std::size_t{8},
                                      std::size_t{256}}) {
    CurrentInkInputModeler batched(0.4);
    batched.start();
    std::vector<CurrentInkRawInput> batch;
    batch.reserve(batchSize);
    for (std::size_t index = 0; index < batchSize; ++index) {
      batch.push_back(raw2(index * 0.01, index * 2.0, index * 0.5));
    }
    batched.extend(batch, batch.back().elapsedTime, false);
    CHECK(batched.rebuildCount() == 1);
  }

  return 0;
}
