#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define INK_ENGINE_NOEXCEPT noexcept
extern "C" {
#else
#define INK_ENGINE_NOEXCEPT
#endif

typedef struct InkEngineOpaque InkEngineOpaque;
typedef InkEngineOpaque *InkEngineRef;

#define INK_ENGINE_API_VERSION 8u
#define INK_ENGINE_MAX_REAL_INPUT_BATCH 256u
#define INK_ENGINE_BATCH_OPERATION_UPDATE 1u
#define INK_ENGINE_BATCH_OPERATION_END 2u

typedef struct InkEngineInput {
  double x;
  double y;
  double time;
  double pressure;
  double tilt;
  double orientation;
} InkEngineInput;

typedef struct InkEnginePoint {
  double x;
  double y;
} InkEnginePoint;

typedef struct InkEngineCubicSegment {
  InkEnginePoint p0;
  InkEnginePoint c1;
  InkEnginePoint c2;
  InkEnginePoint p3;
  size_t sourceStart;
  size_t sourceEnd;
} InkEngineCubicSegment;

typedef struct InkEngineCubicContourRecord {
  size_t segmentStart;
  size_t segmentCount;
  size_t sourceStart;
  size_t sourceEnd;
  uint32_t closed;
} InkEngineCubicContourRecord;

typedef enum InkEngineStatusCode {
  InkEngineStatusOk = 0,
  InkEngineStatusAlreadyInProgress = 1,
  InkEngineStatusNotInProgress = 2,
  InkEngineStatusInvalidEvent = 3,
  InkEngineStatusInvalidInput = 4,
  InkEngineStatusDuplicateInput = 5,
  InkEngineStatusTimeWentBackwards = 6,
  InkEngineStatusReconfigureWhileInProgress = 7,
  InkEngineStatusException = 100,
} InkEngineStatusCode;

typedef enum InkEngineFrameType {
  InkEngineFrameTypeCommitted = 0,
  InkEngineFrameTypePrediction = 1,
  InkEngineFrameTypeFinal = 2,
} InkEngineFrameType;

typedef enum InkEnginePredictionSuppressionReason {
  InkEnginePredictionSuppressionReasonNone = 0,
  InkEnginePredictionSuppressionReasonInactive = 1,
  InkEnginePredictionSuppressionReasonInvalidResult = 2,
  InkEnginePredictionSuppressionReasonGeometryEmpty = 3,
  InkEnginePredictionSuppressionReasonEmptyBatch = 4,
  InkEnginePredictionSuppressionReasonModelNoUnstableOutput = 5,
} InkEnginePredictionSuppressionReason;

typedef enum InkEngineDiagnosticValidity {
  InkEngineDiagnosticNone = 0,
  InkEngineDiagnosticLatestRealRaw = 1u << 0,
  InkEngineDiagnosticLatestPlatformPredictedRaw = 1u << 1,
  InkEngineDiagnosticStableModeledTip = 1u << 2,
  InkEngineDiagnosticRealModeledTip = 1u << 3,
  InkEngineDiagnosticPredictedModeledEndpoint = 1u << 4,
  InkEngineDiagnosticTerminalCrossSection = 1u << 5,
  InkEngineDiagnosticRenderedPredictionEndpoint = 1u << 6,
  InkEngineDiagnosticDirection = 1u << 7,
} InkEngineDiagnosticValidity;

typedef struct InkEnginePredictionDiagnostics {
  uint32_t validityFlags;
  uint32_t suppressionReason;
  uint64_t queuedRealInputCount;
  uint64_t processedRealInputCount;
  uint64_t queuedPredictedInputCount;
  uint64_t processedPredictedInputCount;
  uint64_t stableModeledInputCount;
  uint64_t realModeledInputCount;
  uint64_t fullModeledInputCount;
  double realMovingSpeed;
  double realNormalizedSpeed;
  double predictedMovingSpeed;
  double predictedNormalizedSpeed;
  InkEnginePoint latestRealRawInput;
  InkEnginePoint latestPlatformPredictedRawInput;
  InkEnginePoint stableModeledTip;
  InkEnginePoint realModeledTip;
  InkEnginePoint predictedModeledEndpoint;
  InkEnginePoint terminalLeftEndpoint;
  InkEnginePoint terminalRightEndpoint;
  InkEnginePoint renderedPredictionEndpoint;
  double latestRealRawTime;
  double latestPlatformPredictedRawTime;
  double stableModeledTime;
  double realModeledTime;
  double predictedModeledTime;
  double renderedPredictionTime;
  double realElapsedTime;
  double fullElapsedTime;
  double completeElapsedTime;
  double inputAgeAtReplacement;
  double platformPredictionTemporalLead;
  double modeledPredictionTemporalLead;
  double renderedPredictionTemporalLead;
  double platformPredictionLongitudinalLead;
  double modeledPredictionLongitudinalLead;
  double renderedPredictionLongitudinalLead;
  double platformPredictionLateralError;
  double modeledPredictionLateralError;
  double renderedPredictionLateralError;
  uint64_t modelDurationNanos;
  uint64_t geometryDurationNanos;
  uint64_t rendererReplacementDurationNanos;
  uint64_t rendererDrawDurationNanos;
} InkEnginePredictionDiagnostics;

/*
 * A borrowed view into the engine's reusable frame buffers. Pointers remain
 * valid until the next mutating engine call, cancel, or destroy. Consumers
 * must copy the cubic paths they retain before making another call.
 */
typedef struct InkEngineFrameView {
  uint32_t type;
  uint64_t revision;
  uint64_t committedPointCount;
  const InkEngineCubicSegment *segments;
  size_t segmentCount;
  const InkEngineCubicContourRecord *contours;
  size_t contourCount;

  InkEnginePredictionDiagnostics diagnostics;

} InkEngineFrameView;

InkEngineRef ink_engine_create(void) INK_ENGINE_NOEXCEPT;
void ink_engine_destroy(InkEngineRef engine) INK_ENGINE_NOEXCEPT;

int32_t ink_engine_configure_pen(InkEngineRef engine,
                                        double min_width,
                                        double max_width,
                                        double smoothing,
                                        double logical_display_units_per_page_unit)
    INK_ENGINE_NOEXCEPT;
int32_t ink_engine_begin(InkEngineRef engine,
                                InkEngineInput input) INK_ENGINE_NOEXCEPT;
int32_t ink_engine_update(InkEngineRef engine,
                                 InkEngineInput input) INK_ENGINE_NOEXCEPT;
int32_t ink_engine_end(InkEngineRef engine,
                              InkEngineInput input) INK_ENGINE_NOEXCEPT;
/* Mutates one ordered real-input batch. Operation 1 accepts Move inputs;
 * operation 2 accepts Move inputs followed by one terminal Up. The input
 * array is borrowed for the duration of the call. */
int32_t ink_engine_mutate_batch(
    InkEngineRef engine,
    uint32_t operation,
    const InkEngineInput *inputs,
    size_t input_count) INK_ENGINE_NOEXCEPT;
/* Replaces presentation-only predicted Move inputs; input memory is borrowed
 * for the duration of the call. A zero count clears the prediction view. */
int32_t ink_engine_replace_predicted_inputs(
    InkEngineRef engine,
    const InkEngineInput *inputs,
    size_t input_count,
    double current_time) INK_ENGINE_NOEXCEPT;
void ink_engine_cancel(InkEngineRef engine) INK_ENGINE_NOEXCEPT;

const InkEngineFrameView *ink_engine_frame(InkEngineRef engine) INK_ENGINE_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef INK_ENGINE_NOEXCEPT
