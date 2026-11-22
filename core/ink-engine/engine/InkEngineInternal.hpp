#pragma once

#include "InkEngine.hpp"

#include "input/CommittedCenterline.hpp"
#include "modeling/ContactLifecycle.hpp"
#include "modeling/SignatureBrushTipModeler.hpp"
#include "upstream/UpstreamStrokeGeometry.hpp"
#include "upstream/UpstreamStrokeOutput.hpp"

#include <chrono>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

namespace margelo::nitro::inksignpdf {

namespace detail::engine {

enum class Operation { Update, End };

detail::CommittedCenterlineConfig centerlineConfig(const InkStrokeConfig& config);

InkStrokeStatus fromInputStatus(const detail::InputStatus& status);

std::optional<Vec2> recentRealDirection(
    const std::vector<detail::NormalizedInput>& points);


}  // namespace detail::engine

struct InkEngine::Impl {
  explicit Impl(const InkStrokeConfig& config);

  detail::SignatureBrushTipModeler brush;
  detail::CommittedCenterline centerline;
  detail::ContactLifecycle contact;
  UpstreamStrokeGeometry upstream;
  detail::CommittedCenterlineUpdate centerlineUpdate;
  std::vector<InkStrokeDiagnosticSample> diagnosticSamples;
  bool diagnosticsEnabled = false;
  std::uint64_t revision = 0;
  InkStrokeWorkStats workStats;
  std::uint64_t modelDurationNanos = 0;
  std::uint64_t geometryDurationNanos = 0;

  InkStrokePredictionDiagnostics diagnosticsSnapshot(
      std::size_t predictedModeledInputCount = 0) const;
  void reset();
  InkStrokeStatus replacePredictedInputs(
      std::span<const InkStrokeInput> predictedInputs, double currentTime,
      InkStrokePredictionFrame& output);
  void publishContours(std::size_t committedPointCount,
                       std::size_t modeledPointStart, InkStrokeFrame& output);
};

}  // namespace margelo::nitro::inksignpdf
