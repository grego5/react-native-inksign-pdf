#include "ink-engine/tests/support/TestSupport.hpp"
#include "ink-engine/tests/fixtures/StrokeFixtures.hpp"
#include "input/CommittedCenterline.hpp"
#include "ink-engine/replay-tool/StrokeReplay.hpp"

#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using namespace margelo::nitro::inksignpdf;
using namespace margelo::nitro::inksignpdf::detail;

namespace {

bool same(const NormalizedInput& first, const NormalizedInput& second) {
  return first.eventType == second.eventType &&
      first.position.x == second.position.x &&
      first.position.y == second.position.y && first.time == second.time &&
      first.stylus.pressure == second.stylus.pressure &&
      first.stylus.tilt == second.stylus.tilt &&
      first.stylus.orientation == second.stylus.orientation;
}

bool same(const CenterlineState& first, const CenterlineState& second) {
  return first.position.x == second.position.x &&
      first.position.y == second.position.y &&
      first.velocity.x == second.velocity.x &&
      first.velocity.y == second.velocity.y &&
      first.acceleration.x == second.acceleration.x &&
      first.acceleration.y == second.acceleration.y &&
      first.time == second.time && first.pressure == second.pressure &&
      first.tilt == second.tilt && first.orientation == second.orientation &&
      first.rawSourceIndex == second.rawSourceIndex &&
      first.modeledSourceIndex == second.modeledSourceIndex &&
      first.predicted == second.predicted;
}

bool same(const std::vector<NormalizedInput>& first,
          const std::vector<NormalizedInput>& second) {
  if (first.size() != second.size()) return false;
  for (std::size_t index = 0; index < first.size(); ++index) {
    if (!same(first[index], second[index])) return false;
  }
  return true;
}

void appendModeledStates(
    std::vector<CenterlineState>& destination,
    std::span<const CurrentInkModeledInput> source, std::size_t start) {
  for (std::size_t index = start; index < source.size(); ++index)
    destination.push_back(source[index].state);
}

std::vector<NormalizedInput> run(const std::vector<InkStrokeInput>& inputs) {
  CommittedCenterline centerline;
  CommittedCenterlineUpdate update;
  for (const InkStrokeInput& input : inputs) {
    const InputStatus status = input.eventType == InkStrokeEventType::Down
        ? centerline.begin(input, update)
        : input.eventType == InkStrokeEventType::Move
            ? centerline.update(input, update)
            : centerline.end(input, update);
    CHECK(status.ok());
  }
  return centerline.points();
}

void checkDeterministic(const std::vector<InkStrokeInput>& inputs) {
  const auto first = run(inputs);
  const auto second = run(inputs);
  CHECK(!first.empty());
  CHECK(same(first, second));
  CHECK(first.front().eventType == InkStrokeEventType::Down);
  CHECK(first.back().eventType == InkStrokeEventType::Up);
}

}  // namespace

int main() {
  CommittedCenterlineConfig config;
  CommittedCenterline centerline(config);
  CommittedCenterlineUpdate output;

  CHECK(centerline.begin(
      fixtures::sample(InkStrokeEventType::Down, 0.0, 0.0, 0.0), output).ok());
  CHECK(output.acceptedInput.eventType == InkStrokeEventType::Down);
  CHECK(output.acceptedInput.position.x == 0.0);
  CHECK(output.acceptedInput.position.y == 0.0);
  CHECK(output.acceptedInput.time == 0.0);
  CHECK(output.modeledRealInputs.size() == 1);
  CHECK(output.modeledRealInputs.data() == centerline.modeledInputs().data());
  CHECK(output.stableInputCount == 0);
  CHECK(centerline.points().size() == 1);

  CHECK(centerline.update(
      fixtures::sample(InkStrokeEventType::Move, 0.1, 0.5, 0.0), output).ok());
  CHECK(output.acceptedInput.eventType == InkStrokeEventType::Move);

  CHECK(centerline.update(
      fixtures::sample(InkStrokeEventType::Move, 0.2, 2.0, 0.0), output).ok());
  CHECK(output.acceptedInput.eventType == InkStrokeEventType::Move);
  CHECK(centerline.points().size() >= 2);
  const auto accepted = centerline.points();
  const auto modeledBeforeRejected = centerline.modeledInputs();
  const auto updateBeforeRejected = output;
  CHECK(centerline.update(
      fixtures::sample(InkStrokeEventType::Move, 0.1, 3.0, 0.0), output).code ==
      InputStatusCode::TimeWentBackwards);
  CHECK(same(centerline.points(), accepted));
  CHECK(centerline.modeledInputs().size() == modeledBeforeRejected.size());
  for (std::size_t index = 0; index < modeledBeforeRejected.size(); ++index)
    CHECK(same(centerline.modeledInputs()[index].state,
               modeledBeforeRejected[index].state));
  CHECK(output.stableInputStart == updateBeforeRejected.stableInputStart);
  CHECK(output.stableInputCount == updateBeforeRejected.stableInputCount);
  CHECK(output.modeledRealInputs.data() ==
        updateBeforeRejected.modeledRealInputs.data());

  CHECK(centerline.update(
      fixtures::sample(InkStrokeEventType::Move, 0.2, 2.0, 0.0), output).code ==
      InputStatusCode::DuplicateInput);

  CHECK(centerline.end(
      fixtures::sample(InkStrokeEventType::Up, 0.3, 2.0, 0.0), output).ok());
  CHECK(output.acceptedInput.eventType == InkStrokeEventType::Up);
  CHECK(centerline.points().back().eventType == InkStrokeEventType::Up);

  CommittedCenterlineConfig smoothedConfig;
  smoothedConfig.smoothing = 1.0;
  CommittedCenterline smoothed(smoothedConfig);
  CHECK(smoothed.begin(
      fixtures::sample(InkStrokeEventType::Down, 0.0, 0.0, 0.0), output).ok());
  CHECK(smoothed.update(
      fixtures::sample(InkStrokeEventType::Move, 0.01, 10.0, 0.0), output).ok());
  CHECK(output.modeledRealInputs.back().state.position.x == 10.0);

  // Each real update replaces the suffix after the stable prefix that was
  // already published. The prior endpoint remains mutable until the next
  // contact because the sliding window can revise it.
  CommittedCenterlineConfig frontierConfig;
  frontierConfig.smoothing = 0.4;
  CommittedCenterline frontier(frontierConfig);
  std::vector<CenterlineState> reconstructedStates;
  auto checkReconstructedStates = [&] {
    const auto& modeled = frontier.modeledInputs();
    CHECK(reconstructedStates.size() == modeled.size());
    for (std::size_t index = 0; index < modeled.size(); ++index) {
      CHECK(reconstructedStates[index].position.x ==
            modeled[index].state.position.x);
      CHECK(reconstructedStates[index].position.y ==
            modeled[index].state.position.y);
      if (reconstructedStates[index].velocity.x !=
              modeled[index].state.velocity.x ||
          reconstructedStates[index].velocity.y !=
              modeled[index].state.velocity.y) {
        CHECK(false);
      }
      CHECK(reconstructedStates[index].acceleration.x ==
            modeled[index].state.acceleration.x);
      CHECK(reconstructedStates[index].acceleration.y ==
            modeled[index].state.acceleration.y);
      CHECK(reconstructedStates[index].time == modeled[index].state.time);
      CHECK(reconstructedStates[index].pressure == modeled[index].state.pressure);
      CHECK(reconstructedStates[index].tilt == modeled[index].state.tilt);
      CHECK(reconstructedStates[index].orientation ==
            modeled[index].state.orientation);
    }
  };
  CHECK(frontier.begin(
      fixtures::sample(InkStrokeEventType::Down, 0.0, 0.0, 0.0), output).ok());
  reconstructedStates.clear();
  appendModeledStates(reconstructedStates, output.modeledRealInputs,
                      output.stableInputStart);
  checkReconstructedStates();
  std::size_t previouslyStable = frontier.modelState().stableInputCount;
  CHECK(output.stableInputStart == 0);
  CHECK(output.stableInputCount == previouslyStable);
  for (int index = 1; index <= 12; ++index) {
    CHECK(frontier.update(
        fixtures::sample(InkStrokeEventType::Move, index * 0.1,
                         std::sin(index * 0.4), index * 0.01),
        output).ok());
    reconstructedStates.resize(output.stableInputStart);
    appendModeledStates(reconstructedStates, output.modeledRealInputs,
                        output.stableInputStart);
    checkReconstructedStates();
    CHECK(output.stableInputStart == previouslyStable);
    CHECK(output.stableInputCount == frontier.modelState().stableInputCount);
    CHECK(frontier.modelState().stableInputCount >= previouslyStable);
    previouslyStable = frontier.modelState().stableInputCount;
  }
  const std::size_t stableBeforePrediction =
      frontier.modelState().stableInputCount;
  const auto modeledBeforePrediction = frontier.modeledInputs();
  const auto modelStateBeforePrediction = frontier.modelState();
  const std::vector<CenterlineState> stablePrefix(
      reconstructedStates.begin(),
      reconstructedStates.begin() +
          static_cast<std::ptrdiff_t>(stableBeforePrediction));
  const std::vector<InkStrokeInput> prediction{
      fixtures::sample(InkStrokeEventType::Move, 1.3, 2.0, 0.2)};
  std::size_t acceptedPredictionCount = 0;
  CHECK(frontier.replacePredictedInputs(
      prediction, 1.25, output, &acceptedPredictionCount).ok());
  CHECK(acceptedPredictionCount == 1);
  CHECK(frontier.modeledInputs().size() == modeledBeforePrediction.size());
  CHECK(frontier.modelState().stableInputCount ==
        modelStateBeforePrediction.stableInputCount);
  CHECK(frontier.modelState().realInputCount ==
        modelStateBeforePrediction.realInputCount);
  CHECK(frontier.modelState().completeElapsedTime ==
        modelStateBeforePrediction.completeElapsedTime);
  for (std::size_t index = 0; index < modeledBeforePrediction.size(); ++index) {
    CHECK(frontier.modeledInputs()[index].state.position.x ==
          modeledBeforePrediction[index].state.position.x);
    CHECK(frontier.modeledInputs()[index].state.position.y ==
          modeledBeforePrediction[index].state.position.y);
    CHECK(frontier.modeledInputs()[index].state.velocity.x ==
          modeledBeforePrediction[index].state.velocity.x);
    CHECK(frontier.modeledInputs()[index].state.velocity.y ==
          modeledBeforePrediction[index].state.velocity.y);
    CHECK(frontier.modeledInputs()[index].state.acceleration.x ==
          modeledBeforePrediction[index].state.acceleration.x);
    CHECK(frontier.modeledInputs()[index].state.acceleration.y ==
          modeledBeforePrediction[index].state.acceleration.y);
    CHECK(frontier.modeledInputs()[index].state.time ==
          modeledBeforePrediction[index].state.time);
    CHECK(frontier.modeledInputs()[index].state.pressure ==
          modeledBeforePrediction[index].state.pressure);
    CHECK(frontier.modeledInputs()[index].state.tilt ==
          modeledBeforePrediction[index].state.tilt);
    CHECK(frontier.modeledInputs()[index].state.orientation ==
          modeledBeforePrediction[index].state.orientation);
    CHECK(frontier.modeledInputs()[index].predicted ==
          modeledBeforePrediction[index].predicted);
  }
  CHECK(frontier.modelState().stableInputCount == stableBeforePrediction);
  for (std::size_t index = 0; index < stablePrefix.size(); ++index) {
    CHECK(frontier.modeledInputs()[index].state.position.x ==
          stablePrefix[index].position.x);
    CHECK(frontier.modeledInputs()[index].state.velocity.x ==
          stablePrefix[index].velocity.x);
    CHECK(frontier.modeledInputs()[index].state.acceleration.x ==
          stablePrefix[index].acceleration.x);
    CHECK(frontier.modeledInputs()[index].state.acceleration.y ==
          stablePrefix[index].acceleration.y);
    CHECK(frontier.modeledInputs()[index].state.time == stablePrefix[index].time);
  }

  centerline.cancel();
  CHECK(centerline.points().empty());
  CHECK(centerline.update(
      fixtures::sample(InkStrokeEventType::Move, 0.4, 4.0, 0.0), output).code ==
      InputStatusCode::NotInProgress);

  for (const auto& fixture : fixtures::all()) {
    checkDeterministic(fixture.inputs);
  }

  return 0;
}
