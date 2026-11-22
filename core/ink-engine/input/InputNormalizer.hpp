#pragma once

#include "InkEngine.hpp"

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
  InkStrokeEventType eventType = InkStrokeEventType::Move;
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
  InputStatus begin(const InkStrokeInput& input, NormalizedInput& output);
  InputStatus update(const InkStrokeInput& input, NormalizedInput& output);
  InputStatus end(const InkStrokeInput& input, NormalizedInput& output);
  InputStatus prepareBatch(std::span<const InkStrokeInput> inputs, bool terminal,
                           std::vector<NormalizedInput>& output) const;
  void commitBatch(std::span<const InkStrokeInput> inputs, bool terminal);
  void cancel();

  bool inProgress() const { return inProgress_; }

 private:
  InputStatus accept(const InkStrokeInput& input,
                     InkStrokeEventType expected,
                     NormalizedInput& output);
  static InputStatus validateValues(const InkStrokeInput& input);
  static bool isDuplicate(const InkStrokeInput& first, const InkStrokeInput& second);
  static NormalizedInput normalizeInput(const InkStrokeInput& input);

  bool inProgress_ = false;
  std::optional<InkStrokeInput> lastInput_;
};

}  // namespace margelo::nitro::inksignpdf::detail
