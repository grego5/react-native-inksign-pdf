#include "StrokeEngine.hpp"
#include "input/CurrentInkInputModeler.hpp"
#include "tests/support/TestSupport.hpp"

#include <atomic>
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <new>
#include <vector>

namespace {

std::atomic<std::size_t> allocationCount{0};

void* allocate(std::size_t size) {
  allocationCount.fetch_add(1, std::memory_order_relaxed);
  if (void* memory = std::malloc(size)) return memory;
  throw std::bad_alloc();
}

}  // namespace

void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void* memory, std::size_t) noexcept {
  std::free(memory);
}

using namespace margelo::nitro::inksignpdf;

struct RunResult {
  double milliseconds = 0.0;
  double p50Microseconds = 0.0;
  double p95Microseconds = 0.0;
  double allocationsPerInput = 0.0;
  std::size_t modeledPoints = 0;
  std::uint64_t styleStatesProcessed = 0;
  std::uint64_t tipStatesMaterialized = 0;
  std::uint64_t immutableStatesReused = 0;
  std::uint64_t boundarySearches = 0;
  std::uint64_t scratchBufferGrowth = 0;
  std::uint64_t checksum = 0;
};

RunResult runStroke(int sampleCount, StrokeConfig config,
                    bool simplifyModelers = true) {
  if (simplifyModelers) {
    config.smoothing = 0.0;
  }
  StrokeEngine engine(config);
  StrokeFrame frame;
  CHECK(engine.begin({.eventType = StrokeEventType::Down,
                      .position = {0, 0},
                      .time = 0},
                     frame).ok());

  std::uint64_t checksum = 1469598103934665603ULL;
  std::vector<double> updateDurations;
  updateDurations.reserve(static_cast<std::size_t>(sampleCount));
  const std::size_t allocationsBefore = allocationCount.load();
  const auto start = std::chrono::steady_clock::now();
  for (int index = 1; index <= sampleCount; ++index) {
    const double time = index / 120.0;
    const double x = index * 0.4;
    const double y = std::sin(index * 0.025) * 20.0 +
        std::sin(index * 0.003) * 40.0;
    const auto updateStart = std::chrono::steady_clock::now();
    CHECK(engine.update({.eventType = StrokeEventType::Move,
                         .position = {x, y},
                         .time = time},
                        frame).ok());
    updateDurations.push_back(std::chrono::duration<double, std::micro>(
        std::chrono::steady_clock::now() - updateStart).count());
    for (const ModeledPoint& point : frame.modeledPoints) {
      checksum ^= static_cast<std::uint64_t>(
          std::llround(point.point.x * 1000.0));
      checksum *= 1099511628211ULL;
    }
    for (const auto& contour : frame.contours)
      for (const auto& segment : contour.path.segments) {
        checksum ^= static_cast<std::uint64_t>(std::llround(segment.p0.x * 1000.0));
        checksum *= 1099511628211ULL;
      }
  }
  const auto elapsed = std::chrono::steady_clock::now() - start;
  const std::size_t allocations = allocationCount.load() - allocationsBefore;
  std::sort(updateDurations.begin(), updateDurations.end());
  const StrokeWorkStats work = engine.workStats();

  CHECK(engine.end({.eventType = StrokeEventType::Up,
                    .position = {sampleCount * 0.4, 0},
                    .time = (sampleCount + 1) / 120.0},
                   frame).ok());
  CHECK(frame.isFinal());
  CHECK(!frame.modeledPoints.empty());
  CHECK(!frame.contours.empty());
  CHECK(checksum != 0);
  for (const ModeledPoint& point : frame.modeledPoints) {
    CHECK(std::isfinite(point.point.x));
    CHECK(std::isfinite(point.point.y));
    CHECK(std::isfinite(point.acceleration.x));
    CHECK(std::isfinite(point.acceleration.y));
    CHECK(point.pressure >= 0.0 && point.pressure <= 1.0);
    CHECK(point.radius >= 1e-6);
  }

  return {.milliseconds =
              std::chrono::duration<double, std::milli>(elapsed).count(),
          .p50Microseconds = updateDurations[updateDurations.size() / 2],
          .p95Microseconds = updateDurations[
              static_cast<std::size_t>(updateDurations.size() * 0.95)],
          .allocationsPerInput =
          static_cast<double>(allocations) / sampleCount,
          .modeledPoints = frame.modeledPoints.size(),
          .styleStatesProcessed = work.styleStatesProcessed,
          .tipStatesMaterialized = work.tipStatesMaterialized,
          .immutableStatesReused = work.immutableStatesReused,
          .boundarySearches = work.boundarySearches,
          .scratchBufferGrowth = work.scratchBufferGrowth,
          .checksum = checksum};
}

struct LiveStrokeResult {
  StrokeWorkStats work;
  std::uint64_t contourChecksum = 0;
};

std::uint64_t contourChecksum(const StrokeFrame& frame) {
  std::uint64_t checksum = 1469598103934665603ULL;
  auto add = [&checksum](std::uint64_t value) {
    checksum ^= value;
    checksum *= 1099511628211ULL;
  };
  for (const auto& contour : frame.contours) {
    add(contour.sourceStart); add(contour.sourceEnd);
    add(contour.path.closed ? 1 : 0);
    for (const auto& segment : contour.path.segments) {
      add(std::bit_cast<std::uint64_t>(segment.p0.x));
      add(std::bit_cast<std::uint64_t>(segment.p0.y));
      add(std::bit_cast<std::uint64_t>(segment.c1.x));
      add(std::bit_cast<std::uint64_t>(segment.c1.y));
      add(std::bit_cast<std::uint64_t>(segment.c2.x));
      add(std::bit_cast<std::uint64_t>(segment.c2.y));
      add(std::bit_cast<std::uint64_t>(segment.p3.x));
      add(std::bit_cast<std::uint64_t>(segment.p3.y));
      add(segment.sourceStart); add(segment.sourceEnd);
    }
  }
  return checksum;
}

LiveStrokeResult runLiveStroke(StrokeEngine& engine, StrokeFrame& frame,
                               int sampleCount) {
  CHECK(engine.begin({.eventType = StrokeEventType::Down,
                      .position = {0, 0},
                      .time = 0},
                     frame).ok());
  for (int index = 1; index <= sampleCount; ++index) {
    CHECK(engine.update({.eventType = StrokeEventType::Move,
                         .position = {index * 0.4,
                                      std::sin(index * 0.025) * 20.0 +
                                          std::sin(index * 0.003) * 40.0},
                        .time = index / 120.0},
                        frame).ok());
  }
  const StrokeWorkStats work = engine.workStats();
  const std::uint64_t checksum = contourChecksum(frame);
  engine.cancel();
  return {.work = work, .contourChecksum = checksum};
}

int main() {
  std::vector<RunResult> runs;
  for (const int sampleCount : {64, 128, 256, 512, 1024}) {
    runs.push_back(runStroke(sampleCount, {}));
    std::cout << "incremental " << sampleCount << " inputs, "
              << runs.back().modeledPoints << " modeled points, "
              << runs.back().allocationsPerInput << " allocations/input, "
              << runs.back().milliseconds << " ms, p50/p95 "
              << runs.back().p50Microseconds << "/"
              << runs.back().p95Microseconds << " us, style/tips "
              << runs.back().styleStatesProcessed << "/"
              << runs.back().tipStatesMaterialized << ", boundaries "
              << runs.back().boundarySearches << ", scratch growth "
              << runs.back().scratchBufferGrowth << "\n";
  }

  CHECK(runs.back().checksum != 0);
  CHECK(runs.back().styleStatesProcessed <
        static_cast<std::uint64_t>(runs.back().modeledPoints) * 160);
  CHECK(runs.back().p95Microseconds <
        runs[runs.size() - 2].p95Microseconds * 2.0);
  CHECK(runs.back().tipStatesMaterialized >=
        runs.back().styleStatesProcessed);
  CHECK(runs.back().boundarySearches > 0);

  StrokeEngine warmed;
  StrokeFrame warmedFrame;
  const LiveStrokeResult warmup = runLiveStroke(warmed, warmedFrame, 512);
  // The second pass exercises the frame's cross-stroke path recycling. The
  // first pass alone cannot warm storage that is transferred only when the
  // caller reuses the frame for the next stroke.
  const LiveStrokeResult lifecycleWarmup =
      runLiveStroke(warmed, warmedFrame, 512);
  CHECK(warmup.contourChecksum == lifecycleWarmup.contourChecksum);
  const std::size_t warmedAllocationsBefore = allocationCount.load();
  const LiveStrokeResult warmedResult = runLiveStroke(warmed, warmedFrame, 512);
  const std::size_t warmedAllocations =
      allocationCount.load() - warmedAllocationsBefore;
  std::cout << "warmed 512-input live stroke, " << warmedAllocations
            << " allocations\n";
  const std::size_t plateauAllocationsBefore = allocationCount.load();
  const LiveStrokeResult plateauResult = runLiveStroke(warmed, warmedFrame, 512);
  const std::size_t plateauAllocations =
      allocationCount.load() - plateauAllocationsBefore;
  std::cout << "plateau 512-input live stroke, " << plateauAllocations
            << " allocations\n";
  CHECK(warmedAllocations == plateauAllocations);
  const auto checkPlateau = [](const LiveStrokeResult& result) {
    CHECK(result.work.modelerScratchBufferGrowth == 0);
    CHECK(result.work.centerlineScratchBufferGrowth == 0);
    CHECK(result.work.scratchBufferGrowth == 0);
  };
  checkPlateau(warmedResult);
  checkPlateau(plateauResult);
  CHECK(warmedResult.contourChecksum == plateauResult.contourChecksum);
  CHECK(warmedAllocations > 0);

  const LiveStrokeResult smaller = runLiveStroke(warmed, warmedFrame, 128);
  checkPlateau(smaller);
  const LiveStrokeResult larger = runLiveStroke(warmed, warmedFrame, 1024);
  const LiveStrokeResult largerRepeat = runLiveStroke(warmed, warmedFrame, 1024);
  checkPlateau(largerRepeat);
  CHECK(larger.contourChecksum == largerRepeat.contourChecksum);

  StrokeFrame predictionFrame;
  CHECK(warmed.begin({.eventType = StrokeEventType::Down,
                      .position = {0, 0}, .time = 0}, predictionFrame).ok());
  CHECK(warmed.update({.eventType = StrokeEventType::Move,
                       .position = {4, 1}, .time = 0.1}, predictionFrame).ok());
  StrokePredictionFrame prediction;
  CHECK(warmed.replacePredictedInputs(
      std::array<StrokeInput, 2>{
          StrokeInput{.eventType = StrokeEventType::Move,
                      .position = {5, 2}, .time = 0.2},
          StrokeInput{.eventType = StrokeEventType::Move,
                      .position = {6, 3}, .time = 0.3}},
      0.15, prediction).ok());
  CHECK(!prediction.contours.empty());
  CHECK(warmed.end({.eventType = StrokeEventType::Up,
                    .position = {7, 4}, .time = 0.4}, predictionFrame).ok());
  CHECK(predictionFrame.isFinal());

  StrokeFrame repeatedPredictionFrame;
  CHECK(warmed.begin({.eventType = StrokeEventType::Down,
                      .position = {0, 0}, .time = 1.0},
                     repeatedPredictionFrame).ok());
  CHECK(warmed.update({.eventType = StrokeEventType::Move,
                       .position = {4, 1}, .time = 1.1},
                      repeatedPredictionFrame).ok());
  StrokePredictionFrame repeatedPrediction;
  const std::array<StrokeInput, 2> repeatedPredictionInputs{
      StrokeInput{.eventType = StrokeEventType::Move,
                  .position = {5, 2}, .time = 1.2},
      StrokeInput{.eventType = StrokeEventType::Move,
                  .position = {6, 3}, .time = 1.3}};
  CHECK(warmed.replacePredictedInputs(repeatedPredictionInputs, 1.15,
                                      repeatedPrediction).ok());
  for (int attempt = 0; attempt < 8; ++attempt) {
    CHECK(warmed.replacePredictedInputs(repeatedPredictionInputs, 1.15,
                                        repeatedPrediction).ok());
  }
  CHECK(warmed.end({.eventType = StrokeEventType::Up,
                    .position = {7, 4}, .time = 1.4},
                   repeatedPredictionFrame).ok());

  detail::CurrentInkInputModeler predictionModeler(0.4);
  detail::CurrentInkInputModeler predictionWorkspace(0.4);
  predictionModeler.start();
  const std::array<detail::CurrentInkRawInput, 2> predictionRealInputs{
      detail::CurrentInkRawInput{.position = {0, 0}, .elapsedTime = 0.0},
      detail::CurrentInkRawInput{.position = {4, 1}, .elapsedTime = 0.1}};
  predictionModeler.extend(predictionRealInputs, 0.1, false);
  const std::array<detail::CurrentInkRawInput, 2> predictionRawInputs{
      detail::CurrentInkRawInput{.position = {5, 2}, .elapsedTime = 0.2},
      detail::CurrentInkRawInput{.position = {6, 3}, .elapsedTime = 0.3}};
  std::vector<detail::CurrentInkModeledInput> predictionModeledOutput;
  predictionModeledOutput.reserve(64);
  predictionModeler.predictionSuffix(predictionRawInputs, 0.15,
                                     predictionModeledOutput,
                                     predictionWorkspace);
  const std::size_t modelerPredictionAllocationsBefore = allocationCount.load();
  for (int attempt = 0; attempt < 8; ++attempt) {
    predictionModeler.predictionSuffix(predictionRawInputs, 0.15,
                                       predictionModeledOutput,
                                       predictionWorkspace);
  }
  const std::size_t modelerPredictionAllocations =
      allocationCount.load() - modelerPredictionAllocationsBefore;
  std::cout << "warmed modeler prediction, "
            << modelerPredictionAllocations << " allocations\n";
  CHECK(modelerPredictionAllocations == 0);

  const RunResult productionSmall = runStroke(128, {}, false);
  const RunResult productionLarge = runStroke(256, {}, false);
  CHECK(productionLarge.checksum != 0);
  CHECK(productionSmall.milliseconds > 0.0);
  CHECK(productionLarge.milliseconds > 0.0);
  std::cout << "default modelers 256 inputs, "
            << productionLarge.milliseconds << " ms, p50/p95 "
            << productionLarge.p50Microseconds << "/"
            << productionLarge.p95Microseconds << " us\n";

  return 0;
}
