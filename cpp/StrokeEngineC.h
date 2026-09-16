#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define NSE_STROKE_NOEXCEPT noexcept
extern "C" {
#else
#define NSE_STROKE_NOEXCEPT
#endif

typedef struct NSEStrokeEngine NSEStrokeEngine;
typedef NSEStrokeEngine *NSEStrokeEngineRef;

#define NSE_STROKE_ENGINE_API_VERSION 8u
#define NSE_STROKE_MAX_REAL_INPUT_BATCH 256u
#define NSE_STROKE_BATCH_OPERATION_UPDATE 1u
#define NSE_STROKE_BATCH_OPERATION_END 2u

typedef struct NSEStrokeInput {
  double x;
  double y;
  double time;
  double pressure;
  double tilt;
  double orientation;
} NSEStrokeInput;

typedef struct NSEStrokePoint {
  double x;
  double y;
} NSEStrokePoint;

typedef struct NSEStrokeCubicSegment {
  NSEStrokePoint p0;
  NSEStrokePoint c1;
  NSEStrokePoint c2;
  NSEStrokePoint p3;
  size_t sourceStart;
  size_t sourceEnd;
} NSEStrokeCubicSegment;

typedef struct NSEStrokeCubicContourRecord {
  size_t segmentStart;
  size_t segmentCount;
  size_t sourceStart;
  size_t sourceEnd;
  uint32_t closed;
} NSEStrokeCubicContourRecord;

typedef enum NSEStrokeStatusCode {
  NSEStrokeStatusOk = 0,
  NSEStrokeStatusAlreadyInProgress = 1,
  NSEStrokeStatusNotInProgress = 2,
  NSEStrokeStatusInvalidEvent = 3,
  NSEStrokeStatusInvalidInput = 4,
  NSEStrokeStatusDuplicateInput = 5,
  NSEStrokeStatusTimeWentBackwards = 6,
  NSEStrokeStatusReconfigureWhileInProgress = 7,
  NSEStrokeStatusException = 100,
} NSEStrokeStatusCode;

typedef enum NSEStrokeFrameType {
  NSEStrokeFrameTypeCommitted = 0,
  NSEStrokeFrameTypePrediction = 1,
  NSEStrokeFrameTypeFinal = 2,
} NSEStrokeFrameType;

typedef enum NSEStrokePredictionSuppressionReason {
  NSEStrokePredictionSuppressionReasonNone = 0,
  NSEStrokePredictionSuppressionReasonInactive = 1,
  NSEStrokePredictionSuppressionReasonInvalidResult = 2,
  NSEStrokePredictionSuppressionReasonGeometryEmpty = 3,
  NSEStrokePredictionSuppressionReasonEmptyBatch = 4,
  NSEStrokePredictionSuppressionReasonModelNoUnstableOutput = 5,
} NSEStrokePredictionSuppressionReason;

typedef enum NSEStrokeDiagnosticValidity {
  NSEStrokeDiagnosticNone = 0,
  NSEStrokeDiagnosticLatestRealRaw = 1u << 0,
  NSEStrokeDiagnosticLatestPlatformPredictedRaw = 1u << 1,
  NSEStrokeDiagnosticStableModeledTip = 1u << 2,
  NSEStrokeDiagnosticRealModeledTip = 1u << 3,
  NSEStrokeDiagnosticPredictedModeledEndpoint = 1u << 4,
  NSEStrokeDiagnosticTerminalCrossSection = 1u << 5,
  NSEStrokeDiagnosticRenderedPredictionEndpoint = 1u << 6,
  NSEStrokeDiagnosticDirection = 1u << 7,
} NSEStrokeDiagnosticValidity;

typedef struct NSEStrokePredictionDiagnostics {
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
  NSEStrokePoint latestRealRawInput;
  NSEStrokePoint latestPlatformPredictedRawInput;
  NSEStrokePoint stableModeledTip;
  NSEStrokePoint realModeledTip;
  NSEStrokePoint predictedModeledEndpoint;
  NSEStrokePoint terminalLeftEndpoint;
  NSEStrokePoint terminalRightEndpoint;
  NSEStrokePoint renderedPredictionEndpoint;
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
} NSEStrokePredictionDiagnostics;

/*
 * A borrowed view into the engine's reusable frame buffers. Pointers remain
 * valid until the next mutating engine call, cancel, or destroy. Consumers
 * must copy the cubic paths they retain before making another call.
 */
typedef struct NSEStrokeFrameView {
  uint32_t type;
  uint64_t revision;
  uint64_t committedPointCount;
  const NSEStrokeCubicSegment *segments;
  size_t segmentCount;
  const NSEStrokeCubicContourRecord *contours;
  size_t contourCount;

  NSEStrokePredictionDiagnostics diagnostics;

} NSEStrokeFrameView;

NSEStrokeEngineRef nse_stroke_engine_create(void) NSE_STROKE_NOEXCEPT;
void nse_stroke_engine_destroy(NSEStrokeEngineRef engine) NSE_STROKE_NOEXCEPT;

int32_t nse_stroke_engine_configure_pen(NSEStrokeEngineRef engine,
                                        double min_width,
                                        double max_width,
                                        double smoothing,
                                        double logical_display_units_per_page_unit)
    NSE_STROKE_NOEXCEPT;
int32_t nse_stroke_engine_begin(NSEStrokeEngineRef engine,
                                NSEStrokeInput input) NSE_STROKE_NOEXCEPT;
int32_t nse_stroke_engine_update(NSEStrokeEngineRef engine,
                                 NSEStrokeInput input) NSE_STROKE_NOEXCEPT;
int32_t nse_stroke_engine_end(NSEStrokeEngineRef engine,
                              NSEStrokeInput input) NSE_STROKE_NOEXCEPT;
/* Mutates one ordered real-input batch. Operation 1 accepts Move inputs;
 * operation 2 accepts Move inputs followed by one terminal Up. The input
 * array is borrowed for the duration of the call. */
int32_t nse_stroke_engine_mutate_batch(
    NSEStrokeEngineRef engine,
    uint32_t operation,
    const NSEStrokeInput *inputs,
    size_t input_count) NSE_STROKE_NOEXCEPT;
/* Replaces presentation-only predicted Move inputs; input memory is borrowed
 * for the duration of the call. A zero count clears the prediction view. */
int32_t nse_stroke_engine_replace_predicted_inputs(
    NSEStrokeEngineRef engine,
    const NSEStrokeInput *inputs,
    size_t input_count,
    double current_time) NSE_STROKE_NOEXCEPT;
void nse_stroke_engine_cancel(NSEStrokeEngineRef engine) NSE_STROKE_NOEXCEPT;

const NSEStrokeFrameView *nse_stroke_engine_frame(NSEStrokeEngineRef engine) NSE_STROKE_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef NSE_STROKE_NOEXCEPT
