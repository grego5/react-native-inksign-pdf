#include "replay/StrokeReplay.hpp"
#include "replay/StrokeReplayInternal.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace margelo::nitro::inksignpdf::replay {
namespace {

std::string trim(std::string value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const auto last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::string lower(std::string_view value) {
  std::string result;
  result.reserve(value.size());
  for (const char character : value) {
    result.push_back(static_cast<char>(
        std::tolower(static_cast<unsigned char>(character))));
  }
  return result;
}

bool finite(Vec2 point) {
  return std::isfinite(point.x) && std::isfinite(point.y);
}

const char* frameName(InkStrokeFrameType type) {
  switch (type) {
    case InkStrokeFrameType::Committed: return "committed";
    case InkStrokeFrameType::Prediction: return "prediction";
    case InkStrokeFrameType::Final: return "final";
  }
  return "unknown";
}

void addFailure(Result& result, std::size_t operation, std::string message) {
  result.invariantFailures.push_back("operation " +
      std::to_string(operation) + ": " + std::move(message));
}

bool parseNumber(const std::string& text, double& value) {
  try {
    std::size_t parsed = 0;
    value = std::stod(text, &parsed);
    return parsed == text.size() && std::isfinite(value);
  } catch (const std::exception&) {
    return false;
  }
}

void validateFinalFrame(const InkStrokeFrame& frame, Result& result,
                        std::size_t operation) {
  if (frame.modeledPointStart != 0 ||
      frame.modeledPoints.size() != frame.committedPointCount) {
    addFailure(result, operation, "final frame does not contain the complete centerline");
  }
  if (frame.contours.empty())
    addFailure(result, operation, "final frame has no cubic contours");
  for (const auto& contour : frame.contours) {
    if (!contour.path.closed || contour.path.segments.empty())
      addFailure(result, operation, "final contour is empty or not closed");
  }
}

}  // namespace

bool StageSelection::contains(Stage stage) const {
  switch (stage) {
    case Stage::Input: return input;
    case Stage::Centerline: return centerline;
    case Stage::Geometry: return geometry;
  }
  return false;
}

bool parseOperation(std::string_view rawLine, Operation& operation,
                    std::string& error) {
  std::stringstream stream{std::string(rawLine)};
  std::string field;
  std::vector<std::string> fields;
  while (std::getline(stream, field, ',')) fields.push_back(trim(field));
  if (fields.empty()) {
    error = "empty operation";
    return false;
  }
  const std::string event = lower(fields[0]);
  if (event == "# pen") {
    if (fields.size() != 5) {
      error = "pen configuration expects min_width,max_width,smoothing,display_scale";
      return false;
    }
    double minWidth = 0.0;
    double maxWidth = 0.0;
    double smoothing = 0.0;
    double displayScale = 0.0;
    if (!parseNumber(fields[1], minWidth) || !parseNumber(fields[2], maxWidth) ||
        !parseNumber(fields[3], smoothing) || !parseNumber(fields[4], displayScale)) {
      error = "pen configuration fields must be finite numbers";
      return false;
    }
    if (minWidth <= 0.0 || maxWidth <= 0.0 || displayScale <= 0.0) {
      error = "pen widths and display_scale must be positive";
      return false;
    }
    if (minWidth > maxWidth) {
      error = "min_width must not exceed max_width";
      return false;
    }
    if (smoothing < 0.0 || smoothing > 1.0) {
      error = "smoothing must be between 0 and 1";
      return false;
    }
    // Recorder metadata contains the already-converted page-space widths.
    // displayScale is retained only for the frozen page/display-dependent
    // style distances used by the engine.
    operation = {.type = OperationType::Configure,
                 .config = {.minWidth = minWidth,
                            .maxWidth = maxWidth,
                            .logicalDisplayUnitsPerPageUnit = displayScale,
                            .smoothing = smoothing}};
    return true;
  }
  if (event == "c" || event == "cancel") {
    if (fields.size() != 1) {
      error = "cancel takes no fields";
      return false;
    }
    operation = {.type = OperationType::Cancel};
    return true;
  }
  if (fields.size() < 4 || fields.size() > 7) {
    error = "expected event,time,x,y[,pressure[,tilt[,orientation]]]";
    return false;
  }
  InkStrokeEventType type;
  if (event == "d" || event == "down") type = InkStrokeEventType::Down;
  else if (event == "m" || event == "move") type = InkStrokeEventType::Move;
  else if (event == "u" || event == "up") type = InkStrokeEventType::Up;
  else {
    error = "event must be down, move, up, or cancel";
    return false;
  }
  double time = 0.0;
  double x = 0.0;
  double y = 0.0;
  double pressure = -1.0;
  double tilt = -1.0;
  double orientation = -1.0;
  if (!parseNumber(fields[1], time) || !parseNumber(fields[2], x) ||
      !parseNumber(fields[3], y) ||
      (fields.size() > 4 && !parseNumber(fields[4], pressure)) ||
      (fields.size() > 5 && !parseNumber(fields[5], tilt)) ||
      (fields.size() > 6 && !parseNumber(fields[6], orientation))) {
    error = "input fields must be finite numbers";
    return false;
  }
  operation.type = OperationType::Input;
  operation.input = {.eventType = type,
                     .position = {x, y},
                     .time = time,
                     .pressure = pressure,
                     .tilt = tilt,
                     .orientation = orientation};
  return true;
}

Result run(std::string name, const std::vector<Operation>& operations,
           StageSelection stages, InkStrokeConfig config,
           ContinuityConfig continuity) {
  Result result{.name = std::move(name)};
  InkEngine engine(config);
  engine.enableDiagnostics(true);
  InkStrokeFrame frame;
  std::vector<InkStrokeInput> acceptedInputs;
  std::vector<ModeledPoint> renderedCenterline;
  StrokeContourCollection renderedGeometry;
  std::uint64_t renderedRevision = 0;
  std::size_t nextStroke = 0;
  std::size_t activeStroke = 0;
  for (std::size_t index = 0; index < operations.size(); ++index) {
    const Operation& operation = operations[index];
    if (operation.type == OperationType::Configure) {
      const InkStrokeStatus status = engine.setConfig(operation.config);
      if (status.ok()) engine.enableDiagnostics(true);
      if (!status.ok()) addFailure(result, index, status.message);
      result.records.push_back({.operation = index, .event = "configure"});
      continue;
    }
    if (operation.type == OperationType::Cancel) {
      engine.cancel();
      acceptedInputs.clear();
      renderedCenterline.clear();
      renderedGeometry.clear();
      renderedRevision = 0;
      result.records.push_back({.operation = index, .event = "cancel",
                                .stroke = activeStroke});
      activeStroke = 0;
      continue;
    }
    InkStrokeStatus status;
    std::string event;
    const bool startsStroke = operation.input.eventType == InkStrokeEventType::Down &&
        !engine.inProgress();
    const std::size_t recordStroke = startsStroke ? nextStroke + 1 : activeStroke;
    {
      const InkStrokeInput& input = operation.input;
      event = input.eventType == InkStrokeEventType::Down ? "down" :
          input.eventType == InkStrokeEventType::Move ? "move" : "up";
      if (input.eventType == InkStrokeEventType::Down) {
        renderedGeometry.clear();
        renderedRevision = 0;
      }
      status = input.eventType == InkStrokeEventType::Down ? engine.begin(input, frame) :
          input.eventType == InkStrokeEventType::Move ? engine.update(input, frame) :
                                                    engine.end(input, frame);
      if (status.ok()) acceptedInputs.push_back(input);
    }
    if (!status.ok()) {
      addFailure(result, index, status.message);
      continue;
    }
    if (startsStroke) {
      activeStroke = ++nextStroke;
    }
    if (frame.modeledPointStart > renderedCenterline.size()) {
      addFailure(result, index, "centerline replacement starts past retained data");
    } else {
      renderedCenterline.resize(frame.modeledPointStart);
      renderedCenterline.insert(renderedCenterline.end(), frame.modeledPoints.begin(),
                                frame.modeledPoints.end());
    }
    if (frame.committedPointCount != renderedCenterline.size()) {
      addFailure(result, index, "frame committed count does not match replay state");
    }
    if (frame.revision < renderedRevision) {
      addFailure(result, index, "frame revision moved backwards");
    }
    if (!frame.isFinal()) {
      renderedGeometry = frame.contours;
    } else {
      validateFinalFrame(frame, result, index);
      // Final geometry is already the complete production snapshot. It is
      // deliberately not rebuilt from replay state or a second geometry path.
      renderedGeometry = frame.contours;
    }
    renderedRevision = frame.revision;
    for (const ModeledPoint& point : renderedCenterline) {
      if (!finite(point.point) || !std::isfinite(point.time) ||
          !finite(point.acceleration) || !std::isfinite(point.radius)) {
        addFailure(result, index, "centerline contains a non-finite value");
        break;
      }
    }
    auto checkPath = [&](const CubicPath& path) {
      for (const auto& segment : path.segments) {
        if (!finite(segment.p0) || !finite(segment.c1) ||
            !finite(segment.c2) || !finite(segment.p3)) return false;
      }
      return true;
    };
    auto checkContours = [&](const StrokeContourCollection& contours) {
      for (const auto& contour : contours)
        if (!checkPath(contour.path)) return false;
      return true;
    };
    if (!checkContours(frame.contours)) {
      addFailure(result, index, "geometry contains a non-finite cubic value");
    }
    Record record{.operation = index, .event = event, .stroke = recordStroke,
                  .frameType = frame.type, .revision = frame.revision,
                  .committedPointCount = frame.committedPointCount};
    if (stages.input) record.inputs = acceptedInputs;
    if (stages.centerline) record.centerline = renderedCenterline;
    if (stages.geometry)
      record.geometry = renderedGeometry;
    auto diagnose = [&](std::string stage, const auto& source,
                        const ContinuityBounds& bounds) {
      std::vector<TimedPosition> positions;
      positions.reserve(source.size());
      for (const auto& value : source) {
        if constexpr (std::is_same_v<std::decay_t<decltype(value)>, InkStrokeInput>)
          positions.push_back({.position = value.position, .time = value.time});
        else
          positions.push_back({.position = value.point, .time = value.time});
      }
      auto evaluation = evaluateContinuity(std::move(stage), positions, bounds);
      if (evaluation.failure && result.invariantFailures.empty())
        addFailure(result, index, evaluation.failure->describe());
      record.continuity.push_back(std::move(evaluation.metrics));
    };
    if (stages.input) diagnose("input", acceptedInputs, continuity.input);
    if (stages.centerline)
      diagnose("centerline", renderedCenterline, continuity.centerline);
    record.diagnostics = engine.diagnosticSamples();
    if (frame.isFinal()) record.terminal = engine.terminalDiagnostic();
    if (frame.isFinal() && stages.geometry) {
      record.envelopeSections = detail::buildEnvelopeSections(record.centerline);
      record.publishedGeometry = detail::measurePublishedGeometry(record);
      if (record.publishedGeometry.sampledCubicFailures != 0)
        addFailure(result, index, "published cubic sampling found non-finite geometry");
      if (record.publishedGeometry.widthCrossCheck == WidthCrossCheckStatus::Disagreement)
        addFailure(result, index, "independent section widths disagree with cubic evaluator");
    }
    result.records.push_back(std::move(record));
    if (frame.isFinal()) {
      acceptedInputs.clear();
      renderedCenterline.clear();
      renderedGeometry.clear();
      activeStroke = 0;
    }
  }
  if (engine.inProgress()) addFailure(result, operations.size(), "stroke remains active");
  return result;
}

BaselineMetrics measureBaseline(const Result& result) {
  return detail::measureBaseline(result);
}

bool validateStartupDiagnostics(const Result& result, std::string& error) {
  return detail::validateStartupDiagnostics(result, error);
}

bool writeArtifacts(const Result& result, const std::filesystem::path& directory,
                    StageSelection stages, std::string& error) {
  if (stages.centerline && !validateStartupDiagnostics(result, error)) return false;
  std::error_code filesystemError;
  std::filesystem::create_directories(directory, filesystemError);
  if (filesystemError) {
    error = "could not create output directory: " + filesystemError.message();
    return false;
  }
  if (!detail::writeCsvArtifacts(result, directory, stages, error)) return false;
  return detail::writeSvgArtifacts(result, directory, stages, error);
}

}  // namespace margelo::nitro::inksignpdf::replay
