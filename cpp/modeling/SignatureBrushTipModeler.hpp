#pragma once

#include "StrokeEngine.hpp"
#include "core/StrokePrimitives.hpp"
#include "input/CurrentInkInputModeler.hpp"
#include "ink/strokes/internal/brush_tip_state.h"
#include "modeling/SignatureStrokeStyle.hpp"
#include "modeling/VelocityWidthModel.hpp"

#include <span>
#include <vector>

namespace margelo::nitro::inksignpdf::detail {

// Complete authoritative real modeled sequence and its replacement/stability
// boundaries. Predicted states must never be supplied through this interface.
struct SignatureBrushRealInput {
  std::span<const CurrentInkModeledInput> states;
  std::size_t replacementStart = 0;
  std::size_t stableCount = 0;
  double lastMovingSpeed = 0.0;
  double timeOffset = 0.0;
};

struct StyledTipState {
  Vec2 center;
  double radius = 0.0;
  std::size_t sourceIndex = 0;
};

// All spans borrow owner storage until its next update, finish, predict or reset.
// Prediction results have no new fixed states: their volatile span contains the
// replaceable real tail followed by predicted states.
struct SignatureBrushTipUpdate {
  // Borrows the complete width-derived real sequence (or the disposable
  // prediction sequence for predict()). The view is consumed synchronously by
  // StrokeEngine before the next brush operation.
  std::span<const ModeledPoint> modeledPoints;
  // These spans contain policy output in the representation consumed by
  // Google Ink's BrushTipExtruder.
  std::span<const ink::strokes_internal::BrushTipState>
      newFixedUpstreamStates;
  std::span<const ink::strokes_internal::BrushTipState>
      volatileUpstreamStates;
  std::size_t modeledPointStart = 0;
};

// One continuous signature brush. Adopts Google Ink's distinction between
// stable input and fixed tip states. The modeled-point sequence and reusable
// materialization buffers are owned here; only semantic width state is copied
// for prediction.
class SignatureBrushTipModeler {
 public:
  explicit SignatureBrushTipModeler(const StrokeConfig& config);
  SignatureBrushTipModeler(const SignatureBrushTipModeler&) = delete;
  SignatureBrushTipModeler& operator=(const SignatureBrushTipModeler&) = delete;
  SignatureBrushTipModeler(SignatureBrushTipModeler&&) = delete;
  SignatureBrushTipModeler& operator=(SignatureBrushTipModeler&&) = delete;

  SignatureBrushTipUpdate update(
      SignatureBrushRealInput input,
      StrokeWorkStats& workStats,
      std::vector<StrokeDiagnosticSample>* diagnostics = nullptr);
  SignatureBrushTipUpdate finish(
      SignatureBrushRealInput input,
      StrokeWorkStats& workStats,
      std::vector<StrokeDiagnosticSample>* diagnostics = nullptr);
  SignatureBrushTipUpdate finishDot(
      const NormalizedInput& input, double radius);
  SignatureBrushTipUpdate predict(
      std::span<const CenterlineState> predicted,
      std::vector<StrokeDiagnosticSample>* diagnostics = nullptr);
  // Finish output must be consumed before reset; reset retains all capacities.
  void reset();

  const SignatureStrokeStyle& style() const noexcept { return style_; }
  const std::vector<ModeledPoint>& modeledPoints() const noexcept {
    return modeledPoints_;
  }
  SignatureStrokeStyle::Snapshot styleSnapshot() const noexcept {
    return style_.snapshotForSpeed(lastMovingRealSpeed_).snapshot();
  }

 private:
  SignatureBrushTipUpdate processReal(
      SignatureBrushRealInput input,
      bool terminal, StrokeWorkStats& workStats,
      std::vector<StrokeDiagnosticSample>* diagnostics);
  std::size_t processWidths(
      SignatureBrushRealInput input,
      bool terminal, StrokeWorkStats& workStats,
      std::vector<StrokeDiagnosticSample>* diagnostics);
  SignatureBrushTipUpdate materialize(
      std::size_t stableCount, StrokeWorkStats& workStats,
      std::vector<StrokeDiagnosticSample>* diagnostics);
  SignatureBrushTipUpdate splitUpdate(std::span<const ModeledPoint> points,
                                      std::size_t sourceStart,
                                      std::size_t upstreamSeam);

  // Configuration is immutable. Terminal-speed observation belongs to this
  // owner, separate from the definition and the velocity response checkpoint.
  const SignatureStrokeStyle style_;
  double lastMovingRealSpeed_ = 0.0;
  VelocityWidthModel velocityWidth_;
  VelocityWidthModel::Snapshot widthInitialSnapshot_;
  struct WidthCheckpoint {
    std::size_t index = 0;
    VelocityWidthModel::Snapshot snapshot;
  };
  WidthCheckpoint widthCheckpoint_;
  std::size_t submittedFixedCount_ = 0;
  std::vector<StyledTipState> styledStateScratch_;
  std::vector<ink::strokes_internal::BrushTipState> upstreamStateScratch_;
  std::vector<ModeledPoint> modeledPoints_;
  std::vector<ModeledPoint> predictionPointScratch_;
};

}  // namespace margelo::nitro::inksignpdf::detail
