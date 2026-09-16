#include "fixtures/StrokeFixtures.hpp"
#include "circular/CubicBezierMath.hpp"
#include "replay/StrokeReplay.hpp"
#include "replay/StrokeReplayInternal.hpp"
#include "tests/support/TestSupport.hpp"

#include <algorithm>
#include <cmath>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace margelo::nitro::inksignpdf;

namespace {

bool same(const Vec2& first, const Vec2& second) {
  return first.x == second.x && first.y == second.y;
}

bool same(const ModeledPoint& first, const ModeledPoint& second) {
  return same(first.point, second.point) && first.time == second.time &&
      first.velocity == second.velocity &&
      first.acceleration.x == second.acceleration.x &&
      first.acceleration.y == second.acceleration.y &&
      first.pressure == second.pressure &&
      first.radius == second.radius;
}

bool same(const CubicSegment& first, const CubicSegment& second) {
  return same(first.p0, second.p0) && same(first.c1, second.c1) &&
      same(first.c2, second.c2) && same(first.p3, second.p3) &&
      first.sourceStart == second.sourceStart && first.sourceEnd == second.sourceEnd;
}

bool same(const CubicPath& first, const CubicPath& second) {
  if (first.closed != second.closed || first.segments.size() != second.segments.size())
    return false;
  for (std::size_t i = 0; i < first.segments.size(); ++i)
    if (!same(first.segments[i], second.segments[i])) return false;
  return true;
}

bool same(const StrokeContour& first, const StrokeContour& second) {
  if (first.sourceStart != second.sourceStart || first.sourceEnd != second.sourceEnd)
    return false;
  return same(first.path, second.path);
}

bool same(const StrokeContourCollection& first,
          const StrokeContourCollection& second) {
  if (first.size() != second.size()) return false;
  for (std::size_t i = 0; i < first.size(); ++i)
    if (!same(first[i], second[i])) return false;
  return true;
}

void checkDeterministic(const replay::Result& first,
                        const replay::Result& second) {
  CHECK(first.records.size() == second.records.size());
  for (std::size_t index = 0; index < first.records.size(); ++index) {
    const replay::Record& left = first.records[index];
    const replay::Record& right = second.records[index];
    CHECK(left.event == right.event);
    CHECK(left.frameType == right.frameType);
    CHECK(left.revision == right.revision);
    CHECK(left.committedPointCount == right.committedPointCount);
    CHECK(left.centerline.size() == right.centerline.size());
    CHECK(same(left.geometry, right.geometry));
    CHECK(left.envelopeSections.size() == right.envelopeSections.size());
    CHECK(left.publishedGeometry.evidence.status ==
          right.publishedGeometry.evidence.status);
    CHECK(left.publishedGeometry.evidence.reason ==
          right.publishedGeometry.evidence.reason);
    for (std::size_t point = 0; point < left.centerline.size(); ++point)
      CHECK(same(left.centerline[point], right.centerline[point]));
  }
}

struct EngineSnapshot {
  std::vector<ModeledPoint> centerline;
  StrokeContourCollection geometry;
};

EngineSnapshot replayEngine(const fixtures::Fixture& fixture, bool diagnostics) {
  StrokeConfig config;
  config.smoothing = 0.0;
  StrokeEngine engine(config);
  engine.enableDiagnostics(diagnostics);
  StrokeFrame frame;
  EngineSnapshot snapshot;
  for (std::size_t index = 0; index < fixture.inputs.size(); ++index) {
    const auto& input = fixture.inputs[index];
    const StrokeStatus status = input.eventType == StrokeEventType::Down
        ? engine.begin(input, frame)
        : input.eventType == StrokeEventType::Move
            ? engine.update(input, frame)
            : engine.end(input, frame);
    CHECK(status.ok());
    if (input.eventType == StrokeEventType::Up) {
      snapshot.centerline = frame.modeledPoints;
      snapshot.geometry = frame.contours;
    }
  }
  CHECK(!snapshot.centerline.empty());
  CHECK(!snapshot.geometry.empty());
  return snapshot;
}

std::string readText(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  CHECK(input.good());
  return {std::istreambuf_iterator<char>(input),
          std::istreambuf_iterator<char>()};
}

std::vector<replay::Operation> loadRecording(
    const std::filesystem::path& path) {
  std::ifstream input(path);
  CHECK(input.good());
  std::vector<replay::Operation> operations;
  std::string line;
  while (std::getline(input, line)) {
    const auto first = line.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) continue;
    if (line[first] == '#' && line.compare(first, 5, "# pen") != 0) continue;
    replay::Operation operation;
    std::string error;
    CHECK(replay::parseOperation(line, operation, error));
    operations.push_back(operation);
  }
  return operations;
}

}  // namespace

int main() {
  // Synthetic sampling control: opposite contour winding must not cancel
  // separately filled production paths. No source metadata certifies direction.
  {
    replay::Record record;
    const std::vector<Vec2> corners{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};
    for (bool reverse : {false, true}) {
      StrokeContour contour;
      contour.path.closed = true;
      for (std::size_t i = 0; i < corners.size(); ++i) {
        const auto a = corners[reverse ? (4 - i) % 4 : i];
        const auto b = corners[reverse ? (3 - i) % 4 : (i + 1) % 4];
        contour.path.segments.push_back({a, a, b, b, 0, 1});
      }
      record.geometry.push_back(contour);
    }
    record.envelopeSections.push_back({{0, 0}, {1, 0}, 0, startup::StartupPhase::Nose});
    const auto measured = replay::detail::measurePublishedGeometry(record);
    CHECK(!measured.forwardOrderEvaluated);
    CHECK(measured.widthCrossCheck == replay::WidthCrossCheckStatus::Agreement);
    CHECK(measured.sampledSectionsCompared == 1);
    CHECK(std::abs(measured.sectionWidths.front().sampledWidth - 2.0) < 1e-9);
    record.envelopeSections.front().tangent = {};
    const auto unsupported = replay::detail::measurePublishedGeometry(record);
    CHECK(unsupported.widthCrossCheck == replay::WidthCrossCheckStatus::Unsupported);
    CHECK(unsupported.sampledSectionsCompared == 0);
    CHECK(std::isnan(unsupported.sampledWidthMaximumError));
  }

  using replay::TimedPosition;
  const std::vector<TimedPosition> diagnosticPoints{
      {{0, 0}, 0.0}, {{3, 0}, 1.0}, {{6, 0}, 2.0}, {{18, 0}, 3.0}};
  replay::ContinuityBounds diagnosticBounds;
  const auto diagnostic = replay::evaluateContinuity(
      "centerline", diagnosticPoints, diagnosticBounds);
  CHECK(diagnostic.metrics.adjacentDistance.value == 12.0);
  CHECK(diagnostic.metrics.adjacentDistance.from == 2);
  CHECK(diagnostic.metrics.speed.value == 12.0);
  CHECK(diagnostic.metrics.velocityChange.value == 9.0);
  CHECK(!diagnostic.failure.has_value());

  replay::ContinuityBounds distanceBound;
  distanceBound.adjacentDistance = 2.0;
  distanceBound.speed = 1.0;
  const auto firstMetric = replay::evaluateContinuity(
      "normalization", diagnosticPoints, distanceBound);
  CHECK(firstMetric.failure->metric == "adjacent_distance");

  replay::Operation operation;
  std::string error;
  CHECK(replay::parseOperation("cancel", operation, error));
  CHECK(operation.type == replay::OperationType::Cancel);
  CHECK(replay::parseOperation("down,0,1,2,0.5,0.7,1.2", operation, error));
  CHECK(operation.input.orientation == 1.2);
  CHECK(replay::parseOperation("# pen,0.125,0.25,0.35,2.0", operation, error));
  CHECK(operation.type == replay::OperationType::Configure);
  CHECK(operation.config.minWidth == 0.125);
  CHECK(operation.config.maxWidth == 0.25);
  CHECK(operation.config.smoothing == 0.35);
  CHECK(operation.config.logicalDisplayUnitsPerPageUnit == 2.0);
  CHECK(!replay::parseOperation("# pen,0.125oops,0.25,0.35,2.0", operation, error));
  CHECK(!replay::parseOperation("# pen,0.125,0.25,0.35", operation, error));
  CHECK(!replay::parseOperation("# pen,0.25,0.125,0.35,2.0", operation, error));
  CHECK(!replay::parseOperation("# pen,0.125,0.25,1.1,2.0", operation, error));

  // Diagnostics are an observational sink. Turning them on must not change
  // the authoritative centerline or published contour collection.
  {
    const auto fixture = fixtures::all().front();
    const auto withoutDiagnostics = replayEngine(fixture, false);
    const auto withDiagnostics = replayEngine(fixture, true);
    CHECK(withoutDiagnostics.centerline.size() == withDiagnostics.centerline.size());
    for (std::size_t index = 0; index < withoutDiagnostics.centerline.size(); ++index)
      CHECK(same(withoutDiagnostics.centerline[index], withDiagnostics.centerline[index]));
    CHECK(same(withoutDiagnostics.geometry, withDiagnostics.geometry));

    StrokeEngine engine;
    engine.enableDiagnostics(true);
    StrokeFrame frame;
    for (const auto& input : fixture.inputs) {
      const auto status = input.eventType == StrokeEventType::Down
          ? engine.begin(input, frame)
          : input.eventType == StrokeEventType::Move
              ? engine.update(input, frame)
              : engine.end(input, frame);
      CHECK(status.ok());
    }
    CHECK(!engine.diagnosticSamples().empty());
    const std::size_t diagnosticCapacity = engine.diagnosticSamples().capacity();
    engine.cancel();
    engine.enableDiagnostics(false);
    CHECK(engine.diagnosticSamples().empty());
    CHECK(engine.diagnosticSamples().capacity() >= diagnosticCapacity);

    StrokeFrame disabledFrame;
    const auto disabledFixture = fixtures::all().front();
    for (const auto& input : disabledFixture.inputs) {
      const auto status = input.eventType == StrokeEventType::Down
          ? engine.begin(input, disabledFrame)
          : input.eventType == StrokeEventType::Move
              ? engine.update(input, disabledFrame)
              : engine.end(input, disabledFrame);
      CHECK(status.ok());
    }
    CHECK(engine.diagnosticSamples().empty());
  }

  const auto configured = replay::run("configured", {
      {.type = replay::OperationType::Configure,
       .config = {.minWidth = 0.5, .maxWidth = 1.0, .smoothing = 0.0}},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Down, 0, 0, 0)},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Move, 0.01, 10, 0)},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Up, 0.02, 20, 0)}});
  CHECK(configured.ok());
  CHECK(configured.records.size() == 4);

  StrokeConfig config;
  config.smoothing = 0.0;
  for (const auto& fixture : fixtures::all()) {
    std::vector<replay::Operation> operations;
    for (const auto& input : fixture.inputs) {
      operations.push_back({.type = replay::OperationType::Input,
                            .input = input});
    }
    const auto result = replay::run(std::string(fixture.name), operations, {}, config);
    const auto repeated = replay::run(std::string(fixture.name), operations, {}, config);
    CHECK(result.ok());
    CHECK(repeated.ok());
    checkDeterministic(result, repeated);
    bool sawFinalGeometry = false;
    for (const auto& record : result.records)
      sawFinalGeometry = sawFinalGeometry ||
          !record.geometry.empty();
    CHECK(sawFinalGeometry);
    CHECK(!result.records.front().continuity.empty());
    const auto baseline = replay::measureBaseline(result);
    CHECK(baseline.inputOperationCount == fixture.inputs.size());
    CHECK(baseline.strokeCount == 1);
    CHECK(baseline.committedPointCount > 0);
    CHECK(baseline.outlineSegmentCount > 0);
    CHECK(baseline.maximumRadius > 0.0);
    CHECK(baseline.maximumStartRadius >= baseline.minimumStartRadius);
    for (const auto& record : result.records) {
      if (record.frameType != StrokeFrameType::Final) continue;
      CHECK(!record.envelopeSections.empty());
      CHECK(record.publishedGeometry.evaluated);
      CHECK(record.publishedGeometry.widthCrossCheck !=
            replay::WidthCrossCheckStatus::NotEvaluated);
    }
    std::cout << fixture.name << ": operations=" << baseline.inputOperationCount
              << ", points=" << baseline.committedPointCount
              << ", outline_segments=" << baseline.outlineSegmentCount
              << ", max_radius=" << baseline.maximumRadius
              << ", start_radius=" << baseline.minimumStartRadius << '\n';
  }

  const auto fixture = fixtures::all().front();
  std::vector<replay::Operation> operations;
  for (const auto& input : fixture.inputs)
    operations.push_back({.type = replay::OperationType::Input, .input = input});

  replay::ContinuityConfig strictContinuity;
  strictContinuity.input.adjacentDistance = 0.01;
  strictContinuity.centerline.adjacentDistance = 0.001;
  const auto failed = replay::run(std::string(fixture.name), operations, {}, config,
                                  strictContinuity);
  CHECK(!failed.ok());
  CHECK(failed.invariantFailures.size() == 1);
  CHECK(failed.invariantFailures.front().find("stage=input") != std::string::npos);

  const auto cancelled = replay::run("cancelled", {
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Down, 0, 0, 0)},
      {.type = replay::OperationType::Cancel}});
  CHECK(cancelled.ok());

  const auto recordedOperations = loadRecording(
      std::filesystem::path(NSE_SOURCE_DIR) / "cpp" / "fixtures" /
      "android-stroke-1787607943525.csv");
  const auto recorded = replay::run("android-stroke-1787607943525",
                                    recordedOperations, {}, config);
  const auto recordedAgain = replay::run("android-stroke-1787607943525",
                                         recordedOperations, {}, config);
  CHECK(recorded.ok());
  CHECK(recordedAgain.ok());
  checkDeterministic(recorded, recordedAgain);
  const auto recordedBaseline = replay::measureBaseline(recorded);
  CHECK(recordedBaseline.inputOperationCount == 105);
  CHECK(recordedBaseline.strokeCount == 3);
  std::size_t recordedUnsupported = 0;
  for (const auto& record : recorded.records)
    if (record.frameType == StrokeFrameType::Final &&
        record.publishedGeometry.evaluated &&
        record.publishedGeometry.evidence.status ==
            startup::StartupEvidenceStatus::Unsupported)
      ++recordedUnsupported;
  CHECK(recordedUnsupported >= 1);
  for (const replay::Record& record : recorded.records) {
    if (record.event != "up" || record.centerline.size() < 2) continue;
    const ModeledPoint& previous = record.centerline[record.centerline.size() - 2];
    const ModeledPoint& terminal = record.centerline.back();
    if (!same(previous.point, terminal.point)) continue;
    CHECK(previous.velocity == terminal.velocity);
    CHECK(previous.radius == terminal.radius);
  }

  const auto smoothingOperations = loadRecording(
      std::filesystem::path(NSE_SOURCE_DIR) / "cpp" / "fixtures" /
      "android-stroke-1787609628336.csv");
  const auto smoothingReplay = replay::run("android-stroke-1787609628336",
                                           smoothingOperations, {}, config);
  const auto smoothingReplayAgain = replay::run(
      "android-stroke-1787609628336", smoothingOperations, {}, config);
  CHECK(smoothingReplay.ok());
  CHECK(smoothingReplayAgain.ok());
  checkDeterministic(smoothingReplay, smoothingReplayAgain);
  const auto smoothingBaseline = replay::measureBaseline(smoothingReplay);
  CHECK(smoothingBaseline.inputOperationCount == 431);
  CHECK(smoothingBaseline.strokeCount == 1);
  CHECK(smoothingBaseline.maximumRadius < 1.7);

  const auto exportOperations = loadRecording(
      std::filesystem::path(NSE_SOURCE_DIR) / "cpp" / "fixtures" /
      "android-stroke-1787613500303.csv");
  const auto exportReplay = replay::run("android-stroke-1787613500303",
                                        exportOperations, {}, config);
  const auto exportReplayAgain = replay::run(
      "android-stroke-1787613500303", exportOperations, {}, config);
  CHECK(exportReplay.ok());
  CHECK(exportReplayAgain.ok());
  checkDeterministic(exportReplay, exportReplayAgain);
  const auto exportBaseline = replay::measureBaseline(exportReplay);
  CHECK(exportBaseline.inputOperationCount == 366);
  CHECK(exportBaseline.strokeCount == 1);
  CHECK(exportBaseline.maximumRadius < 1.4);

  // A completed multi-stroke replay must preserve stroke identity in both the
  // v1 envelope table and every per-stroke SVG snapshot.
  const auto multiStroke = replay::run("multistroke", {
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Down, 0.00, 0, 0)},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Move, 0.01, 10, 0)},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Up, 0.02, 20, 0)},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Down, 0.10, 100, 0)},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Move, 0.11, 110, 0)},
      {.type = replay::OperationType::Input,
       .input = fixtures::sample(StrokeEventType::Up, 0.12, 120, 0)}});
  CHECK(multiStroke.ok());
  CHECK(replay::measureBaseline(multiStroke).strokeCount == 2);
  std::vector<const replay::Record*> finalRecords;
  for (const auto& record : multiStroke.records)
    if (record.frameType == StrokeFrameType::Final) finalRecords.push_back(&record);
  CHECK(finalRecords.size() == 2);
  CHECK(finalRecords[0]->stroke == 1);
  CHECK(finalRecords[1]->stroke == 2);

  const auto artifactDirectory = std::filesystem::temp_directory_path() /
      ("react-native-inksign-replay-" + std::to_string(
          std::chrono::steady_clock::now().time_since_epoch().count()));
  std::string artifactError;
  CHECK(replay::writeArtifacts(multiStroke, artifactDirectory, {}, artifactError));
  for (const auto* finalRecord : finalRecords) {
    const auto finalPath = artifactDirectory /
        ("multistroke-stroke-" + std::to_string(finalRecord->stroke) +
         "-final-op-" + std::to_string(finalRecord->operation) + ".svg");
    CHECK(std::filesystem::exists(finalPath));
    const auto finalSvg = readText(finalPath);
    CHECK(finalSvg.find("stroke=" + std::to_string(finalRecord->stroke) +
                       " operation=" + std::to_string(finalRecord->operation) +
                       " stage=final") != std::string::npos);
    const replay::Record* firstMoving = nullptr;
    const replay::Record* lastNonterminal = nullptr;
    for (const auto& record : multiStroke.records) {
      if (record.stroke == finalRecord->stroke &&
          record.frameType != StrokeFrameType::Final &&
          !record.geometry.empty() &&
          std::any_of(record.diagnostics.begin(), record.diagnostics.end(),
                      [](const auto& diagnostic) {
                        return diagnostic.real && !diagnostic.predicted &&
                            diagnostic.segmentDistance > 0.0;
                      }))
        if (firstMoving == nullptr) firstMoving = &record;
        lastNonterminal = &record;
    }
    for (const auto& record : multiStroke.records) {
      if (record.stroke != finalRecord->stroke || record.geometry.empty()) continue;
      if (&record == firstMoving) {
        CHECK(std::filesystem::exists(artifactDirectory /
            ("multistroke-stroke-" + std::to_string(record.stroke) +
             "-first-moving-op-" + std::to_string(record.operation) + ".svg")));
      }
    }
    CHECK(lastNonterminal != nullptr || firstMoving == nullptr);
  }
  const auto envelopeCsv = readText(artifactDirectory / "multistroke-envelope.csv");
  CHECK(envelopeCsv.find("# schema=stroke-envelope-v1;") != std::string::npos);
  CHECK(envelopeCsv.find("\n2,1,") != std::string::npos);
  CHECK(envelopeCsv.find("\n5,2,") != std::string::npos);
  const auto diagnosticsCsv =
      readText(artifactDirectory / "multistroke-diagnostics.csv");
  CHECK(diagnosticsCsv.find("# schema=stroke-diagnostics-v11;") !=
        std::string::npos);
  CHECK(diagnosticsCsv.find("dt_seconds") != std::string::npos);
  CHECK(diagnosticsCsv.find("turn_factor") != std::string::npos);
  CHECK(diagnosticsCsv.find("effective_speed_display") != std::string::npos);
  CHECK(diagnosticsCsv.find("target_radius_page") != std::string::npos);
  CHECK(diagnosticsCsv.find("radius_page") != std::string::npos);
  CHECK(diagnosticsCsv.find("segment_distance_page") != std::string::npos);
  CHECK(diagnosticsCsv.find("max_radius_change_page") == std::string::npos);
  CHECK(diagnosticsCsv.find("limited_target_radius_page") == std::string::npos);
  CHECK(diagnosticsCsv.find("response_distance_page") != std::string::npos);
  CHECK(diagnosticsCsv.find("response_alpha") != std::string::npos);
  CHECK(diagnosticsCsv.find("final_radius_page") != std::string::npos);
  CHECK(diagnosticsCsv.find("head_") == std::string::npos);
  CHECK(diagnosticsCsv.find("head_length_page") == std::string::npos);
  CHECK(diagnosticsCsv.find("startup_attempted") == std::string::npos);
  CHECK(!std::filesystem::exists(artifactDirectory / "multistroke-final.svg"));
  std::error_code artifactCleanupError;
  std::filesystem::remove_all(artifactDirectory, artifactCleanupError);
  CHECK(!artifactCleanupError);

  // Synthetic production-replay cases keep the input recipe explicit while
  // exercising the real engine and published cubic contours. Rotation is
  // compared after inverse rotation and the measured discrepancy is reported;
  // no tolerance is widened here to make the comparison pass.
  {
    const std::vector<std::string> synthetic{
        "synthetic-moderate-straight",
        "synthetic-fast-straight",
        "synthetic-moderate-curve",
        "synthetic-fast-curve",
        "synthetic-moderate-curve-short",
        "synthetic-fast-curve-short",
        "synthetic-accel-before-reference",
        "synthetic-accel-across-reference",
        "synthetic-accel-after-reference"};
    StrokeConfig syntheticConfig;
    syntheticConfig.smoothing = 0.0;
    std::vector<replay::Result> syntheticResults;
    syntheticResults.reserve(synthetic.size() * 3);
    for (const auto& base : synthetic) {
      for (const int angle : {0, 45, 90}) {
        const std::string name = angle == 0
            ? base : base + "-rot" + std::to_string(angle);
        const auto operations = loadRecording(
            std::filesystem::path(NSE_SOURCE_DIR) / "cpp" / "fixtures" /
            (name + ".csv"));
        const auto result = replay::run(name, operations, {}, syntheticConfig);
        const auto repeated = replay::run(name, operations, {}, syntheticConfig);
        CHECK(result.ok());
        CHECK(repeated.ok());
        checkDeterministic(result, repeated);
        const auto baseline = replay::measureBaseline(result);
        CHECK(baseline.strokeCount == 1);
        CHECK(baseline.outlineSegmentCount > 0);
        syntheticResults.push_back(result);
      }
    }
    auto finalRecord = [](const replay::Result& result) -> const replay::Record& {
      for (const auto& record : result.records)
        if (record.frameType == StrokeFrameType::Final) return record;
      std::exit(EXIT_FAILURE);
    };
    auto inverseRotate = [](Vec2 point, int degrees) {
      constexpr double pi = 3.141592653589793238462643383279502884;
      const double angle = -static_cast<double>(degrees) * pi / 180.0;
      return Vec2{point.x * std::cos(angle) - point.y * std::sin(angle),
                  point.x * std::sin(angle) + point.y * std::cos(angle)};
    };
    auto sampleBoundary = [&](const replay::Record& record, int degrees) {
      std::vector<Vec2> points;
      for (const auto& contour : record.geometry) {
        for (const auto& segment : contour.path.segments) {
          for (int sample = 0; sample <= 32; ++sample) {
            Vec2 point = detail::cubicPoint(
                segment, static_cast<double>(sample) / 32.0);
            if (degrees != 0) point = inverseRotate(point, degrees);
            points.push_back(point);
          }
        }
      }
      return points;
    };
    auto boundaryDistance = [&](const replay::Record& baseRecord,
                                const replay::Record& rotatedRecord, int degrees) {
      const auto baseBoundary = sampleBoundary(baseRecord, 0);
      const auto rotatedBoundary = sampleBoundary(rotatedRecord, degrees);
      auto directedMaximum = [](const std::vector<Vec2>& source,
                                const std::vector<Vec2>& target) {
        double maximum = 0.0;
        for (const auto& point : source) {
          double nearestSquared = std::numeric_limits<double>::infinity();
          for (const auto& candidate : target) {
            const double dx = point.x - candidate.x;
            const double dy = point.y - candidate.y;
            nearestSquared = std::min(nearestSquared, dx * dx + dy * dy);
          }
          maximum = std::max(maximum, std::sqrt(nearestSquared));
        }
        return maximum;
      };
      double maximum = std::max(directedMaximum(baseBoundary, rotatedBoundary),
                                directedMaximum(rotatedBoundary, baseBoundary));
      std::size_t mismatches =
          std::abs(static_cast<long long>(baseRecord.geometry.size()) -
                   static_cast<long long>(rotatedRecord.geometry.size()));
      for (std::size_t contour = 0;
           contour < std::min(baseRecord.geometry.size(), rotatedRecord.geometry.size());
           ++contour) {
        mismatches +=
            std::abs(static_cast<long long>(baseRecord.geometry[contour].path.segments.size()) -
                     static_cast<long long>(rotatedRecord.geometry[contour].path.segments.size()));
      }
      return std::pair{maximum, mismatches};
    };
    for (std::size_t baseIndex = 0; baseIndex < synthetic.size(); ++baseIndex) {
      const auto& baseRecord = finalRecord(syntheticResults[baseIndex * 3]);
      for (const int angle : {45, 90}) {
        const auto& rotatedRecord =
            finalRecord(syntheticResults[baseIndex * 3 + (angle == 45 ? 1 : 2)]);
        CHECK(baseRecord.inputs.size() == rotatedRecord.inputs.size());
        double inputError = 0.0;
        for (std::size_t index = 0; index < baseRecord.inputs.size(); ++index) {
          const auto actual = inverseRotate(rotatedRecord.inputs[index].position, angle);
          inputError = std::max(inputError,
              std::abs(baseRecord.inputs[index].position.x - actual.x));
          inputError = std::max(inputError,
              std::abs(baseRecord.inputs[index].position.y - actual.y));
          CHECK(baseRecord.inputs[index].time == rotatedRecord.inputs[index].time);
        }
      const auto [boundaryError, segmentMismatches] =
            boundaryDistance(baseRecord, rotatedRecord, angle);
        std::cout << "synthetic rotation " << synthetic[baseIndex] << " "
                  << angle << "deg: input_max_error=" << inputError
                  << ", sampled_boundary_max_distance=" << boundaryError
                  << ", segment_count_mismatch=" << segmentMismatches << '\n';
      }
      const auto& diagnostics = baseRecord.diagnostics;
      CHECK(!diagnostics.empty());
      const auto firstMoving = std::find_if(
          diagnostics.begin(), diagnostics.end(),
          [](const auto& diagnostic) { return diagnostic.modeledIndex == 0; });
      CHECK(firstMoving != diagnostics.end());
      const double minimumRadius = std::min_element(
          diagnostics.begin(), diagnostics.end(),
          [](const auto& first, const auto& second) {
            return first.radius < second.radius;
          })->radius;
      CHECK(firstMoving->radius == minimumRadius);
      for (const auto& diagnostic : diagnostics) {
        CHECK(std::isfinite(diagnostic.targetRadius));
        CHECK(std::isfinite(diagnostic.radius));
        CHECK(std::isfinite(diagnostic.finalRadius));
        CHECK(diagnostic.responseAlpha >= 0.0);
        CHECK(diagnostic.responseAlpha <= 1.0);
      }
    }
  }
  return 0;
}
