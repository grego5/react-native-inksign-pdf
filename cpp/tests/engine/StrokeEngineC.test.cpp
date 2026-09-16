#include "StrokeEngineC.h"
#include "tests/support/TestSupport.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace {
NSEStrokeInput input(double x, double y, double time) {
  return {.x = x, .y = y, .time = time, .pressure = -1.0,
          .tilt = -1.0, .orientation = -1.0};
}

void checkSegment(const NSEStrokeCubicSegment& segment) {
  CHECK(std::isfinite(segment.p0.x) && std::isfinite(segment.p0.y));
  CHECK(std::isfinite(segment.c1.x) && std::isfinite(segment.c1.y));
  CHECK(std::isfinite(segment.c2.x) && std::isfinite(segment.c2.y));
  CHECK(std::isfinite(segment.p3.x) && std::isfinite(segment.p3.y));
  CHECK(segment.sourceStart <= segment.sourceEnd);
}

struct FrameSnapshot {
  std::uint32_t type = 0;
  std::uint64_t revision = 0;
  std::uint64_t committedPointCount = 0;
  std::vector<NSEStrokeCubicSegment> segments;
  std::vector<NSEStrokeCubicContourRecord> contours;
};

FrameSnapshot snapshot(const NSEStrokeFrameView& frame) {
  FrameSnapshot result{.type = frame.type,
                       .revision = frame.revision,
                       .committedPointCount = frame.committedPointCount,
                       };
  if (frame.segmentCount > 0)
    result.segments.assign(frame.segments, frame.segments + frame.segmentCount);
  if (frame.contourCount > 0)
    result.contours.assign(frame.contours, frame.contours + frame.contourCount);
  return result;
}

bool same(const NSEStrokeCubicSegment& a, const NSEStrokeCubicSegment& b) {
  return a.p0.x == b.p0.x && a.p0.y == b.p0.y &&
      a.c1.x == b.c1.x && a.c1.y == b.c1.y &&
      a.c2.x == b.c2.x && a.c2.y == b.c2.y &&
      a.p3.x == b.p3.x && a.p3.y == b.p3.y &&
      a.sourceStart == b.sourceStart && a.sourceEnd == b.sourceEnd;
}

bool same(const NSEStrokeCubicContourRecord& a,
          const NSEStrokeCubicContourRecord& b) {
  return a.segmentStart == b.segmentStart &&
      a.segmentCount == b.segmentCount && a.sourceStart == b.sourceStart &&
      a.sourceEnd == b.sourceEnd && a.closed == b.closed;
}

bool same(const FrameSnapshot& a, const FrameSnapshot& b) {
  if (a.type != b.type || a.revision != b.revision ||
      a.committedPointCount != b.committedPointCount ||
      a.segments.size() != b.segments.size() ||
      a.contours.size() != b.contours.size()) return false;
  for (std::size_t index = 0; index < a.segments.size(); ++index)
    if (!same(a.segments[index], b.segments[index])) return false;
  for (std::size_t index = 0; index < a.contours.size(); ++index)
    if (!same(a.contours[index], b.contours[index])) return false;
  return true;
}
}

int main() {
  CHECK(nse_stroke_engine_frame(nullptr) == nullptr);
  CHECK(nse_stroke_engine_configure_pen(nullptr, 1.0, 2.0, 0.5, 1.0) ==
        NSEStrokeStatusInvalidInput);
  NSEStrokeEngineRef engine = nse_stroke_engine_create();
  CHECK(engine != nullptr);
  CHECK(nse_stroke_engine_configure_pen(engine, 1.0, 4.0, 0.0, 1.0) ==
        NSEStrokeStatusOk);
  CHECK(nse_stroke_engine_configure_pen(engine, 4.0, 1.0, 0.0, 1.0) ==
        NSEStrokeStatusInvalidInput);
  CHECK(nse_stroke_engine_begin(engine, input(0, 0, 0)) == NSEStrokeStatusOk);
  const NSEStrokeFrameView* frame = nse_stroke_engine_frame(engine);
  CHECK(frame->segmentCount == 0 && frame->contourCount == 0);

  CHECK(nse_stroke_engine_update(engine, input(4, 0, 0.01)) == NSEStrokeStatusOk);
  frame = nse_stroke_engine_frame(engine);
  CHECK(std::isfinite(frame->diagnostics.realMovingSpeed));
  CHECK(frame->diagnostics.realMovingSpeed >= 0.0);
  CHECK(frame->diagnostics.realNormalizedSpeed >= 0.0 &&
        frame->diagnostics.realNormalizedSpeed <= 1.0);
  for (size_t i = 0; i < frame->segmentCount; ++i) checkSegment(frame->segments[i]);
  for (size_t i = 0; i < frame->contourCount; ++i) {
    const auto& contour = frame->contours[i];
    CHECK(contour.closed == 1);
    CHECK(contour.segmentStart + contour.segmentCount <= frame->segmentCount);
    CHECK(contour.sourceStart <= contour.sourceEnd);
  }

  const NSEStrokeInput predicted[] = {input(6, 0, 0.02), input(8, 0, 0.03)};
  CHECK(nse_stroke_engine_replace_predicted_inputs(engine, predicted, 2, 0.015) ==
        NSEStrokeStatusOk);
  frame = nse_stroke_engine_frame(engine);
  CHECK(frame->type == NSEStrokeFrameTypePrediction);
  CHECK(frame->contourCount > 0);
  CHECK(std::isfinite(frame->diagnostics.predictedMovingSpeed));
  CHECK(frame->diagnostics.predictedMovingSpeed >= 0.0);
  CHECK(frame->diagnostics.predictedNormalizedSpeed >= 0.0 &&
        frame->diagnostics.predictedNormalizedSpeed <= 1.0);
  CHECK(nse_stroke_engine_replace_predicted_inputs(engine, nullptr, 0, 0.015) ==
        NSEStrokeStatusOk);
  frame = nse_stroke_engine_frame(engine);
  CHECK(frame->segmentCount == 0 && frame->contourCount == 0);
  CHECK(frame->diagnostics.suppressionReason ==
        NSEStrokePredictionSuppressionReasonEmptyBatch);

  CHECK(nse_stroke_engine_end(engine, input(8, 0, 0.02)) == NSEStrokeStatusOk);
  frame = nse_stroke_engine_frame(engine);
  CHECK(frame->type == NSEStrokeFrameTypeFinal);
  CHECK(frame->contourCount > 0);
  for (size_t i = 0; i < frame->segmentCount; ++i) checkSegment(frame->segments[i]);
  for (size_t i = 0; i < frame->contourCount; ++i) {
    const auto& contour = frame->contours[i];
    CHECK(contour.closed == 1);
    CHECK(contour.segmentStart + contour.segmentCount <= frame->segmentCount);
  }

  nse_stroke_engine_cancel(engine);
  frame = nse_stroke_engine_frame(engine);
  CHECK(frame->segmentCount == 0 && frame->contourCount == 0);

  CHECK(nse_stroke_engine_begin(engine, input(0, 0, 1.0)) ==
        NSEStrokeStatusOk);
  const std::array<NSEStrokeInput, 2> moveBatch{
      input(2, 0, 1.01), input(4, 1, 1.02)};
  CHECK(nse_stroke_engine_mutate_batch(
            engine, 1u, moveBatch.data(), moveBatch.size()) ==
        NSEStrokeStatusOk);
  frame = nse_stroke_engine_frame(engine);
  CHECK(frame->diagnostics.queuedRealInputCount == 3);
  const std::array<NSEStrokeInput, 2> terminalBatch{
      input(5, 2, 1.03), input(6, 3, 1.04)};
  CHECK(nse_stroke_engine_mutate_batch(
            engine, 2u, terminalBatch.data(), terminalBatch.size()) ==
        NSEStrokeStatusOk);
  frame = nse_stroke_engine_frame(engine);
  CHECK(frame->type == NSEStrokeFrameTypeFinal);
  CHECK(frame->diagnostics.queuedRealInputCount == 5);

  CHECK(nse_stroke_engine_begin(engine, input(0, 0, 2.0)) ==
        NSEStrokeStatusOk);
  const std::array<NSEStrokeInput, 2> invalidBatch{
      input(1, 0, 2.1), input(2, 0, 2.0)};
  CHECK(nse_stroke_engine_mutate_batch(
            engine, 1u, invalidBatch.data(), invalidBatch.size()) ==
        NSEStrokeStatusTimeWentBackwards);
  CHECK(nse_stroke_engine_update(engine, input(3, 0, 2.2)) ==
        NSEStrokeStatusOk);

  auto runPredictionReplacement = []() {
    NSEStrokeEngineRef value = nse_stroke_engine_create();
    CHECK(value != nullptr);
    CHECK(nse_stroke_engine_configure_pen(value, 1.0, 4.0, 0.0, 1.0) ==
          NSEStrokeStatusOk);
    CHECK(nse_stroke_engine_begin(value, input(0, 0, 3.0)) ==
          NSEStrokeStatusOk);
    CHECK(nse_stroke_engine_update(value, input(4, 0, 3.01)) ==
          NSEStrokeStatusOk);
    FrameSnapshot real = snapshot(*nse_stroke_engine_frame(value));
    const NSEStrokeInput firstPrediction[] = {input(6, 0, 3.02)};
    CHECK(nse_stroke_engine_replace_predicted_inputs(
              value, firstPrediction, 1, 3.015) == NSEStrokeStatusOk);
    FrameSnapshot prediction = snapshot(*nse_stroke_engine_frame(value));
    CHECK(prediction.type == NSEStrokeFrameTypePrediction);
    CHECK(!prediction.contours.empty());

    const NSEStrokeInput revisedPrediction[] = {
        input(6, 0, 3.02), input(8, 0, 3.03)};
    CHECK(nse_stroke_engine_replace_predicted_inputs(
              value, revisedPrediction, 2, 3.025) == NSEStrokeStatusOk);
    FrameSnapshot revised = snapshot(*nse_stroke_engine_frame(value));
    CHECK(revised.type == NSEStrokeFrameTypePrediction);
    CHECK(!revised.contours.empty());

    CHECK(nse_stroke_engine_replace_predicted_inputs(value, nullptr, 0, 3.025) ==
          NSEStrokeStatusOk);
    FrameSnapshot empty = snapshot(*nse_stroke_engine_frame(value));
    CHECK(empty.type == NSEStrokeFrameTypePrediction);
    CHECK(empty.segments.empty() && empty.contours.empty());
    CHECK(prediction.contours.size() != empty.contours.size());
    CHECK(real.contours.size() != empty.contours.size());

    CHECK(nse_stroke_engine_update(value, input(6, 0, 3.02)) ==
          NSEStrokeStatusOk);
    FrameSnapshot realAfterPrediction = snapshot(*nse_stroke_engine_frame(value));
    CHECK(nse_stroke_engine_end(value, input(8, 0, 3.03)) ==
          NSEStrokeStatusOk);
    FrameSnapshot final = snapshot(*nse_stroke_engine_frame(value));
    CHECK(final.type == NSEStrokeFrameTypeFinal);
    nse_stroke_engine_destroy(value);
    return std::array{real, prediction, revised, empty, realAfterPrediction, final};
  };

  const auto predictedSequence = runPredictionReplacement();
  NSEStrokeEngineRef reference = nse_stroke_engine_create();
  CHECK(reference != nullptr);
  CHECK(nse_stroke_engine_configure_pen(reference, 1.0, 4.0, 0.0, 1.0) ==
        NSEStrokeStatusOk);
  CHECK(nse_stroke_engine_begin(reference, input(0, 0, 3.0)) ==
        NSEStrokeStatusOk);
  CHECK(nse_stroke_engine_update(reference, input(4, 0, 3.01)) ==
        NSEStrokeStatusOk);
  const FrameSnapshot referenceReal =
      snapshot(*nse_stroke_engine_frame(reference));
  CHECK(nse_stroke_engine_update(reference, input(6, 0, 3.02)) ==
        NSEStrokeStatusOk);
  const FrameSnapshot referenceAfterPrediction =
      snapshot(*nse_stroke_engine_frame(reference));
  CHECK(nse_stroke_engine_end(reference, input(8, 0, 3.03)) ==
        NSEStrokeStatusOk);
  const FrameSnapshot referenceFinal =
      snapshot(*nse_stroke_engine_frame(reference));
  CHECK(same(predictedSequence[0], referenceReal));
  CHECK(same(predictedSequence[4], referenceAfterPrediction));
  CHECK(same(predictedSequence[5], referenceFinal));
  nse_stroke_engine_destroy(reference);

  nse_stroke_engine_destroy(engine);
  return 0;
}
