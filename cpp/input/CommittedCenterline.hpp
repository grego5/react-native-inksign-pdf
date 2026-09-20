#pragma once

#include "input/InputNormalizer.hpp"
#include "core/StrokePrimitives.hpp"
#include "input/CurrentInkInputModeler.hpp"

#include <optional>
#include <span>
#include <vector>

namespace margelo::nitro::inksignpdf::detail {

struct CommittedCenterlineConfig {
  double smoothing = 0.0;
};

struct CommittedCenterlineUpdate {
  NormalizedInput acceptedInput;
  // Borrows the complete authoritative real modeled range owned by the
  // centerline modeler. The view is valid until the next centerline mutation.
  // It is never an append delta. The predicted suffix is presentation-only.
  std::size_t stableInputStart = 0;
  std::size_t stableInputCount = 0;
  std::span<const CurrentInkModeledInput> modeledRealInputs;
  std::vector<CenterlineState> predictedSuffix;
};

class CommittedCenterline {
 public:
  explicit CommittedCenterline(CommittedCenterlineConfig config = {});

  InputStatus begin(const InkStrokeInput& input, CommittedCenterlineUpdate& output);
  InputStatus update(const InkStrokeInput& input, CommittedCenterlineUpdate& output);
  InputStatus end(const InkStrokeInput& input, CommittedCenterlineUpdate& output);
  InputStatus updateBatch(std::span<const InkStrokeInput> inputs,
                          CommittedCenterlineUpdate& output);
  InputStatus endBatch(std::span<const InkStrokeInput> inputs,
                       CommittedCenterlineUpdate& output);
  void cancel();

  InputStatus replacePredictedInputs(
      std::span<const InkStrokeInput> predictedInputs,
      double currentTime,
      CommittedCenterlineUpdate& output,
      std::size_t* acceptedInputCount = nullptr);

  const std::vector<NormalizedInput>& points() const { return points_; }
  const CurrentInkModelState& modelState() const noexcept {
    return modeler_.state();
  }
  const std::vector<CurrentInkModeledInput>& modeledInputs() const noexcept {
    return modeler_.modeledInputs();
  }
  std::size_t realInputCount() const noexcept {
    return modeler_.realInputCount();
  }
  const std::optional<InkStrokeInput>& latestRealInput() const noexcept {
    return latestRealInput_;
  }
  double strokeStartTime() const noexcept { return strokeStartTime_; }
  double latestRealInputTime() const noexcept { return latestRealInputTime_; }
  std::uint64_t scratchBufferGrowth() const noexcept {
    return scratchBufferGrowth_;
  }
  std::uint64_t modelScratchBufferGrowth() const noexcept {
    return modeler_.scratchBufferGrowth();
  }
  Vec2 lastRealMovingVelocity() const noexcept {
    return modeler_.lastRealMovingVelocity();
  }

 private:
  enum class Operation { Begin, Update, End };

  InputStatus process(const InkStrokeInput& input,
                      Operation operation,
                      CommittedCenterlineUpdate& output);
  InputStatus processBatch(std::span<const InkStrokeInput> inputs,
                           Operation operation,
                           CommittedCenterlineUpdate& output);

  static CurrentInkRawInput makeRawInput(const NormalizedInput& input,
                                         double strokeStartTime,
                                         std::size_t sourceIndex);
  void fillUpdate(CommittedCenterlineUpdate& output,
                  const NormalizedInput& acceptedInput);

  InputNormalizer normalizer_;
  CurrentInkInputModeler modeler_;
  std::vector<NormalizedInput> points_;
  std::vector<NormalizedInput> normalizedBatchScratch_;
  std::vector<CurrentInkRawInput> rawBatchScratch_;
  std::vector<CurrentInkRawInput> predictedRawScratch_;
  std::vector<CurrentInkModeledInput> predictedModeledScratch_;
  CurrentInkInputModeler predictionWorkspace_;
  std::optional<InkStrokeInput> latestRealInput_;
  // The next real replacement must begin at the stable prefix that the
  // caller has already received. Everything after that prefix remains
  // replaceable because smoothing may revise it on the next contact.
  std::size_t lastPublishedStableCount_ = 0;
  double strokeStartTime_ = 0.0;
  double latestRealInputTime_ = 0.0;
  std::uint64_t scratchBufferGrowth_ = 0;
};

}  // namespace margelo::nitro::inksignpdf::detail
