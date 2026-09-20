#include "input/InputNormalizer.hpp"

#include <utility>

#include "core/StrokePrimitives.hpp"

namespace margelo::nitro::inksignpdf::detail {
namespace {

bool validOptional(double value) {
  return value == -1.0 || (isFinite(value) && value >= 0.0);
}

std::optional<double> optionalValue(double value) {
  return value == -1.0 ? std::nullopt : std::optional<double>{value};
}

}  // namespace

InputStatus InputNormalizer::begin(const InkStrokeInput& input,
                                   NormalizedInput& output) {
  if (inProgress_) {
    return {InputStatusCode::AlreadyInProgress,
            "A stroke is already in progress."};
  }
  if (input.eventType != InkStrokeEventType::Down) {
    return {InputStatusCode::InvalidEvent,
            "Stroke event does not match the current lifecycle."};
  }
  if (const InputStatus status = validateValues(input); !status.ok()) {
    return status;
  }

  NormalizedInput normalized = normalizeInput(input);
  lastInput_ = input;
  output = std::move(normalized);
  inProgress_ = true;
  return InputStatus::success();
}

InputStatus InputNormalizer::update(const InkStrokeInput& input,
                                    NormalizedInput& output) {
  if (!inProgress_) {
    return {InputStatusCode::NotInProgress, "No stroke is in progress."};
  }
  return accept(input, InkStrokeEventType::Move, output);
}

InputStatus InputNormalizer::end(const InkStrokeInput& input,
                                 NormalizedInput& output) {
  if (!inProgress_) {
    return {InputStatusCode::NotInProgress, "No stroke is in progress."};
  }
  const InputStatus status = accept(input, InkStrokeEventType::Up, output);
  if (status.ok()) inProgress_ = false;
  return status;
}

InputStatus InputNormalizer::prepareBatch(
    std::span<const InkStrokeInput> inputs, bool terminal,
    std::vector<NormalizedInput>& output) const {
  if (!inProgress_) {
    return {InputStatusCode::NotInProgress, "No stroke is in progress."};
  }
  if (inputs.empty()) {
    return {InputStatusCode::InvalidValue, "Input batch must not be empty."};
  }
  output.clear();
  output.reserve(inputs.size());
  std::optional<InkStrokeInput> previous = lastInput_;
  for (std::size_t index = 0; index < inputs.size(); ++index) {
    const InkStrokeEventType expected = terminal && index + 1 == inputs.size()
                                         ? InkStrokeEventType::Up
                                         : InkStrokeEventType::Move;
    const InkStrokeInput& input = inputs[index];
    if (input.eventType != expected) {
      return {InputStatusCode::InvalidEvent,
              "Stroke event does not match the current lifecycle."};
    }
    if (const InputStatus status = validateValues(input); !status.ok())
      return status;
    if (previous) {
      if (input.time < previous->time) {
        return {InputStatusCode::TimeWentBackwards,
                "Stroke input timestamps must be monotonic."};
      }
      if (isDuplicate(input, *previous)) {
        return {InputStatusCode::DuplicateInput,
                "Duplicate stroke input was received."};
      }
    }
    output.push_back(normalizeInput(input));
    previous = input;
  }
  return InputStatus::success();
}

void InputNormalizer::commitBatch(std::span<const InkStrokeInput> inputs,
                                  bool terminal) {
  lastInput_ = inputs.back();
  if (terminal) inProgress_ = false;
}

void InputNormalizer::cancel() {
  inProgress_ = false;
  lastInput_.reset();
}

InputStatus InputNormalizer::accept(const InkStrokeInput& input,
                                    InkStrokeEventType expected,
                                    NormalizedInput& output) {
  if (input.eventType != expected) {
    return {InputStatusCode::InvalidEvent,
            "Stroke event does not match the current lifecycle."};
  }
  if (const InputStatus status = validateValues(input); !status.ok()) {
    return status;
  }
  if (lastInput_) {
    if (input.time < lastInput_->time) {
      return {InputStatusCode::TimeWentBackwards,
              "Stroke input timestamps must be monotonic."};
    }
    if (isDuplicate(input, *lastInput_)) {
      return {InputStatusCode::DuplicateInput,
              "Duplicate stroke input was received."};
    }
  }

  NormalizedInput normalized = normalizeInput(input);
  lastInput_ = input;
  output = std::move(normalized);
  return InputStatus::success();
}

InputStatus InputNormalizer::validateValues(const InkStrokeInput& input) {
  if (!isFinite(input.position) || !isFinite(input.time) || input.time < 0.0 ||
      !validOptional(input.pressure) || !validOptional(input.tilt) ||
      !validOptional(input.orientation)) {
    return {InputStatusCode::InvalidValue,
            "Stroke input contains a non-finite or invalid value."};
  }
  return InputStatus::success();
}

bool InputNormalizer::isDuplicate(const InkStrokeInput& first,
                                  const InkStrokeInput& second) {
  return first.eventType == second.eventType && first.time == second.time &&
         first.position.x == second.position.x &&
         first.position.y == second.position.y &&
         first.pressure == second.pressure && first.tilt == second.tilt &&
         first.orientation == second.orientation;
}

NormalizedInput InputNormalizer::normalizeInput(const InkStrokeInput& input) {
  return {.eventType = input.eventType,
          .position = input.position,
          .time = input.time,
          .stylus = {.pressure = optionalValue(input.pressure),
                     .tilt = optionalValue(input.tilt),
                     .orientation = optionalValue(input.orientation)}};
}

}  // namespace margelo::nitro::inksignpdf::detail
