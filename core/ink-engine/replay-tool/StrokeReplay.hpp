#pragma once

#include "InkEngine.hpp"
#include "circular/StartupEnvelope.hpp"
#include "ink-engine/replay-tool/ContinuityDiagnostics.hpp"

#include <filesystem>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace margelo::nitro::inksignpdf::replay {

enum class OperationType { Input, Cancel, Configure };

struct Operation {
  OperationType type = OperationType::Input;
  InkStrokeInput input;
  InkStrokeConfig config;
};

enum class Stage { Input, Centerline, Geometry };

struct StageSelection {
  bool input = true;
  bool centerline = true;
  bool geometry = true;

  bool contains(Stage stage) const;
};

enum class WidthCrossCheckStatus { NotEvaluated, Unsupported, Agreement, Disagreement };

struct SectionWidthCrossCheck {
  double sampledWidth = std::numeric_limits<double>::quiet_NaN();
  double evaluatorWidth = std::numeric_limits<double>::quiet_NaN();
  WidthCrossCheckStatus status = WidthCrossCheckStatus::Unsupported;
};

struct PublishedGeometryMetrics {
  bool evaluated = false;
  startup::StartupEnvelopeEvidence evidence;
  std::size_t shoulderSection = std::numeric_limits<std::size_t>::max();
  std::size_t bodyJoinSection = std::numeric_limits<std::size_t>::max();
  std::size_t terminalSection = std::numeric_limits<std::size_t>::max();
  double shoulderArclength = std::numeric_limits<double>::quiet_NaN();
  double bodyJoinArclength = std::numeric_limits<double>::quiet_NaN();
  double terminalArclength = std::numeric_limits<double>::quiet_NaN();
  bool forwardOrderEvaluated = false;
  std::size_t forwardOrderViolations = 0;
  std::size_t sampledCubicPoints = 0;
  std::size_t sampledCubicFailures = 0;
  std::size_t sampledSectionFailures = 0;
  std::size_t sampledWidthDisagreements = 0;
  double sampledWidthMaximumError = std::numeric_limits<double>::quiet_NaN();
  WidthCrossCheckStatus widthCrossCheck = WidthCrossCheckStatus::NotEvaluated;
  std::size_t sampledSectionsCompared = 0;
  std::vector<SectionWidthCrossCheck> sectionWidths;
};

struct Record {
  std::size_t operation = 0;
  std::string event;
  // One-based identity for the active completed stroke. Zero identifies
  // configuration/cancel records that do not belong to a stroke.
  std::size_t stroke = 0;
  InkStrokeFrameType frameType = InkStrokeFrameType::Committed;
  std::uint64_t revision = 0;
  std::size_t committedPointCount = 0;
  std::vector<InkStrokeInput> inputs;
  std::vector<ModeledPoint> centerline;
  std::vector<InkStrokeDiagnosticSample> diagnostics;
  // These sections are reconstructed by replay from the actual modeled
  // centerline. They are measurement inputs, never a production geometry
  // or width policy.
  std::vector<startup::StartupSection> envelopeSections;
  InkStrokeTerminalDiagnostic terminal;
  StrokeContourCollection geometry;
  PublishedGeometryMetrics publishedGeometry;
  std::vector<ContinuityMetrics> continuity;
};

struct BaselineMetrics {
  std::size_t inputOperationCount = 0;
  std::size_t committedPointCount = 0;
  std::size_t outlineSegmentCount = 0;
  std::size_t contourCount = 0;
  std::size_t strokeCount = 0;
  std::size_t serializedFrameBytes = 0;
  std::uint64_t transportHash = 0;
  double maximumChordLength = 0.0;
  double maximumRadius = 0.0;
  double minimumStartRadius = 0.0;
  double maximumStartRadius = 0.0;
};

struct ContinuityConfig {
  ContinuityBounds input;
  ContinuityBounds centerline;
};

struct Result {
  std::string name;
  std::vector<Record> records;
  std::vector<std::string> invariantFailures;

  bool ok() const { return invariantFailures.empty(); }
};

bool parseOperation(std::string_view line, Operation& operation,
                    std::string& error);
Result run(std::string name, const std::vector<Operation>& operations,
           StageSelection stages = {}, InkStrokeConfig config = {},
           ContinuityConfig continuity = {});
BaselineMetrics measureBaseline(const Result& result);
bool writeArtifacts(const Result& result, const std::filesystem::path& directory,
                    StageSelection stages, std::string& error);

}  // namespace margelo::nitro::inksignpdf::replay
