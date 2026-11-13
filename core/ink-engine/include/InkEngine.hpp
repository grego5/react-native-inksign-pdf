#pragma once

#include <cstddef>
#include <cstdint>
#include "primitives/Vec2.hpp"
#include "primitives/StrokeOutline.hpp"
#include <memory>
#include <span>
#include <vector>

namespace margelo::nitro::inksignpdf {

inline constexpr std::uint32_t kInkEngineApiVersion = 8;
inline constexpr std::size_t kMaxPredictedInputBatch = 64;
inline constexpr std::size_t kMaxRealInputBatch = 256;

enum class InkStrokeEventType { Down, Move, Up };

struct InkStrokeInput {
  InkStrokeEventType eventType = InkStrokeEventType::Move;
  Vec2 position;
  // Monotonic seconds in an arbitrary clock domain (not milliseconds).
  double time = 0.0;
  // A negative value means that the device did not provide pressure.
  double pressure = -1.0;
  double tilt = -1.0;
  double orientation = -1.0;
};

struct InkStrokeConfig {
  // Public pen widths are diameters in page units.
  double minWidth = 2.0;
  double maxWidth = 4.0;
  // Frozen at stroke start so logical display-space taper lengths remain
  // stable while the viewport changes.
  double logicalDisplayUnitsPerPageUnit = 1.0;
  // Google Ink sliding-window strength. Zero is exact passthrough; one maps
  // to the maximum 25 ms temporal averaging window.
  double smoothing = 0.4;
};

struct ModeledPoint {
  Vec2 point;
  Vec2 tangent;
  double time = 0.0;
  double distance = 0.0;
  double runningLength = 0.0;
  double velocity = 0.0;
  Vec2 acceleration;
  double pressure = 0.5;
  double tilt = -1.0;
  double orientation = -1.0;
  double radius = 0.0;
};

enum class InkStrokeStatusCode {
  Ok,
  AlreadyInProgress,
  NotInProgress,
  InvalidEvent,
  InvalidInput,
  DuplicateInput,
  TimeWentBackwards,
  ReconfigureWhileInProgress,
};

struct InkStrokeStatus {
  InkStrokeStatusCode code = InkStrokeStatusCode::Ok;
  const char* message = "";

  bool ok() const { return code == InkStrokeStatusCode::Ok; }
  static InkStrokeStatus success() { return {}; }
};

// Native-only deterministic work counters. They are cumulative for the active
// stroke and are intentionally not part of the JavaScript or C ABI surfaces.
struct InkStrokeWorkStats {
  std::uint64_t widthPointsProcessed = 0;
  std::uint64_t styleStatesProcessed = 0;
  std::uint64_t tipStatesMaterialized = 0;
  std::uint64_t immutableStatesReused = 0;
  std::uint64_t boundarySearches = 0;
  std::uint64_t scratchBufferGrowth = 0;
  std::uint64_t modelerScratchBufferGrowth = 0;
  std::uint64_t centerlineScratchBufferGrowth = 0;
  std::uint64_t frameFlatteningCapacityGrowth = 0;
};

struct InkStrokeDiagnosticSample {
  std::size_t modeledIndex = 0;
  std::size_t rawSourceIndex = 0;
  std::size_t modeledSourceIndex = 0;
  double time = 0.0;
  Vec2 position;
  double runningLength = 0.0;
  Vec2 velocity;
  double displaySpeed = 0.0;
  double normalizedSpeed = 0.0;
  Vec2 acceleration;
  double forwardAcceleration = 0.0;
  double lateralAcceleration = 0.0;
  double runningLengthDisplay = 0.0;
  double forwardAccelerationDisplay = 0.0;
  double lateralAccelerationDisplay = 0.0;
  double dtSeconds = 0.0;
  double turnFactor = 1.0;
  double effectiveSpeedDisplay = 0.0;
  double targetRadius = 0.0;
  double radius = 0.0;
  double segmentDistance = 0.0;
  double responseDistancePage = 0.0;
  double responseAlpha = 0.0;
  double finalRadius = 0.0;
  bool stable = false;
  bool real = true;
  std::size_t fixedCenterlineFrontier = 0;
  std::size_t contourSourceStart = 0;
  std::size_t contourSourceEnd = 0;
  bool predicted = false;
};

struct InkStrokeTerminalDiagnostic {
  bool valid = false;
  double lastValidMovingSpeed = 0.0;
  double normalizedTerminalSpeed = 0.0;
  double selectedTaperDistance = 0.0;
  double remainingArclength = 0.0;
  double taperMultiplier = 1.0;
  double taperedRadius = 0.0;
  bool exactContact = false;
};

enum class InkStrokeFrameType { Committed, Prediction, Final };

enum class InkStrokePredictionSuppressionReason {
  None = 0,
  Inactive = 1,
  InvalidResult = 2,
  GeometryEmpty = 3,
  EmptyBatch = 4,
  ModelNoUnstableOutput = 5,
};

enum InkStrokeDiagnosticValidity : std::uint32_t {
  InkStrokeDiagnosticNone = 0,
  InkStrokeDiagnosticLatestRealRaw = 1u << 0,
  InkStrokeDiagnosticLatestPlatformPredictedRaw = 1u << 1,
  InkStrokeDiagnosticStableModeledTip = 1u << 2,
  InkStrokeDiagnosticRealModeledTip = 1u << 3,
  InkStrokeDiagnosticPredictedModeledEndpoint = 1u << 4,
  InkStrokeDiagnosticTerminalCrossSection = 1u << 5,
  InkStrokeDiagnosticRenderedPredictionEndpoint = 1u << 6,
  InkStrokeDiagnosticDirection = 1u << 7,
};

// One low-frequency snapshot of the real/predicted boundaries.
// Position and time fields are meaningful only when their validity bit is set.
// Lead values are signed along the most recent distinct real direction;
// lateral values are absolute perpendicular error in page units.
struct InkStrokePredictionDiagnostics {
  std::uint32_t validityFlags = InkStrokeDiagnosticNone;
  InkStrokePredictionSuppressionReason suppressionReason =
      InkStrokePredictionSuppressionReason::None;

  std::uint64_t queuedRealInputCount = 0;
  std::uint64_t processedRealInputCount = 0;
  std::uint64_t queuedPredictedInputCount = 0;
  std::uint64_t processedPredictedInputCount = 0;
  std::uint64_t stableModeledInputCount = 0;
  std::uint64_t realModeledInputCount = 0;
  std::uint64_t fullModeledInputCount = 0;
  double realMovingSpeed = 0.0;
  double realNormalizedSpeed = 0.0;
  double predictedMovingSpeed = 0.0;
  double predictedNormalizedSpeed = 0.0;

  Vec2 latestRealRawInput;
  Vec2 latestPlatformPredictedRawInput;
  Vec2 stableModeledTip;
  Vec2 realModeledTip;
  Vec2 predictedModeledEndpoint;
  Vec2 terminalLeftEndpoint;
  Vec2 terminalRightEndpoint;
  Vec2 renderedPredictionEndpoint;

  double latestRealRawTime = 0.0;
  double latestPlatformPredictedRawTime = 0.0;
  double stableModeledTime = 0.0;
  double realModeledTime = 0.0;
  double predictedModeledTime = 0.0;
  double renderedPredictionTime = 0.0;
  double realElapsedTime = 0.0;
  double fullElapsedTime = 0.0;
  double completeElapsedTime = 0.0;
  double inputAgeAtReplacement = 0.0;

  double platformPredictionTemporalLead = 0.0;
  double modeledPredictionTemporalLead = 0.0;
  double renderedPredictionTemporalLead = 0.0;
  double platformPredictionLongitudinalLead = 0.0;
  double modeledPredictionLongitudinalLead = 0.0;
  double renderedPredictionLongitudinalLead = 0.0;
  double platformPredictionLateralError = 0.0;
  double modeledPredictionLateralError = 0.0;
  double renderedPredictionLateralError = 0.0;

  std::uint64_t modelDurationNanos = 0;
  std::uint64_t geometryDurationNanos = 0;
  std::uint64_t rendererReplacementDurationNanos = 0;
  std::uint64_t rendererDrawDurationNanos = 0;
};

struct InkStrokePredictionFrame {
  // Prediction geometry is a complete disposable snapshot of the current
  // upstream outline collection. It is replaced on every prediction update.
  StrokeContourCollection contours;

  InkStrokePredictionDiagnostics diagnostics;

  void clear() {
    contours.clear();
    diagnostics = {};
  }
};

// A caller-owned frame. Its vectors remain valid until the caller reuses or
// destroys the frame; they never alias mutable InkEngine storage. Live
// frames are complete replacement snapshots; Prediction is a presentation-only
// preview; Final is the complete export snapshot.
struct InkStrokeFrame {
  InkStrokeFrameType type = InkStrokeFrameType::Committed;
  std::uint64_t revision = 0;
  std::size_t committedPointCount = 0;
  InkStrokePredictionDiagnostics diagnostics;

  // Live frames: modeledPoints starts at modeledPointStart and is the
  // replacement suffix. Final frames contain the complete centerline and use
  // start zero.
  std::size_t modeledPointStart = 0;
  std::vector<ModeledPoint> modeledPoints;

  StrokeContourCollection contours;

  bool isFinal() const { return type == InkStrokeFrameType::Final; }
};

class InkEngine {
 public:
  explicit InkEngine(InkStrokeConfig config = {});
  ~InkEngine();

  InkEngine(const InkEngine&) = delete;
  InkEngine& operator=(const InkEngine&) = delete;
  InkEngine(InkEngine&&) noexcept;
  InkEngine& operator=(InkEngine&&) noexcept;

  // Configuration is immutable during a stroke so every frame uses one
  // coherent model.
  InkStrokeStatus setConfig(InkStrokeConfig config);
  const InkStrokeConfig& config() const { return config_; }

  InkStrokeStatus begin(const InkStrokeInput& input, InkStrokeFrame& output);
  InkStrokeStatus update(const InkStrokeInput& input, InkStrokeFrame& output);
  InkStrokeStatus end(const InkStrokeInput& input, InkStrokeFrame& output);
  InkStrokeStatus updateBatch(std::span<const InkStrokeInput> inputs,
                           InkStrokeFrame& output);
  InkStrokeStatus endBatch(std::span<const InkStrokeInput> inputs,
                        InkStrokeFrame& output);
  void cancel();

  // Replaces presentation-only predicted input. The span is borrowed for the
  // duration of the call; no predicted raw input becomes stroke history.
  InkStrokeStatus replacePredictedInputs(
      std::span<const InkStrokeInput> predictedInputs,
      double currentTime,
      InkStrokePredictionFrame& output);

  bool inProgress() const;
  const std::vector<ModeledPoint>& modeledPoints() const;
  const InkStrokeWorkStats& workStats() const noexcept;
  void recordFrameFlatteningCapacityGrowth() noexcept;
  // Enables the replay/debug sink before a stroke starts. Disabled by
  // default so normal live strokes do not allocate, write, or scan samples.
  void enableDiagnostics(bool enabled);
  const std::vector<InkStrokeDiagnosticSample>& diagnosticSamples() const noexcept;
  const InkStrokeTerminalDiagnostic& terminalDiagnostic() const noexcept {
    return terminalDiagnostic_;
  }

 private:
  static InkStrokeConfig validateConfig(InkStrokeConfig config);

  InkStrokeConfig config_;
  struct Impl;
  std::unique_ptr<Impl> impl_;
  InkStrokeTerminalDiagnostic terminalDiagnostic_;
};

}  // namespace margelo::nitro::inksignpdf
