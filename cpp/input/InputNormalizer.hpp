#pragma once

#include "StrokeEngine.hpp"

#include <cstddef>
#include <optional>
#include <span>
#include <vector>

namespace margelo::nitro::inksignpdf::detail {

struct StylusSample {
  std::optional<double> pressure;
  std::optional<double> tilt;
  std::optional<double> orientation;
};

struct NormalizedInput {
  StrokeEventType eventType = StrokeEventType::Move;
  Vec2 position;
  double time = 0.0;
  StylusSample stylus;
};

enum class InputStatusCode {
  Ok,
  AlreadyInProgress,
  NotInProgress,
  InvalidEvent,
  InvalidValue,
  DuplicateInput,
  TimeWentBackwards,
};

struct InputStatus {
  InputStatusCode code = InputStatusCode::Ok;
  const char* message = "";

  bool ok() const { return code == InputStatusCode::Ok; }
  static InputStatus success() { return {}; }
};

class InputNormalizer {
 public:
  InputStatus begin(const StrokeInput& input, NormalizedInput& output);
  InputStatus update(const StrokeInput& input, NormalizedInput& output);
  InputStatus end(const StrokeInput& input, NormalizedInput& output);
  InputStatus prepareBatch(std::span<const StrokeInput> inputs, bool terminal,
                           std::vector<NormalizedInput>& output) const;
  void commitBatch(std::span<const StrokeInput> inputs, bool terminal);
  void cancel();

  bool inProgress() const { return inProgress_; }

 private:
  InputStatus accept(const StrokeInput& input,
                     StrokeEventType expected,
                     NormalizedInput& output);
  static InputStatus validateValues(const StrokeInput& input);
  static bool isDuplicate(const StrokeInput& first, const StrokeInput& second);
  static NormalizedInput normalizeInput(const StrokeInput& input);

  bool inProgress_ = false;
  std::optional<StrokeInput> lastInput_;
};

}  // namespace margelo::nitro::inksignpdf::detail
