#include "fixtures/StrokeFixtures.hpp"
#include "replay/StrokeReplay.hpp"

#include <filesystem>
#include <fstream>
#include <cmath>
#include <iostream>
#include <optional>
#include <sstream>

using namespace margelo::nitro::inksignpdf;

namespace {
enum class ConfigSource { Current, Recorded, Value };

struct ConfigValue {
  ConfigSource source = ConfigSource::Current;
  double value = 0.0;
};

struct Options {
  std::optional<std::filesystem::path> input;
  std::optional<std::string> fixture;
  bool all = false;
  bool invariantsOnly = false;
  bool summary = false;
  replay::StageSelection stages;
  std::filesystem::path output = "diagnostics";
  ConfigValue minWidth;
  ConfigValue maxWidth;
  ConfigValue smoothing;
  ConfigValue displayScale;
};

void usage() {
  std::cerr << "Usage: stroke_engine_cli (--input FILE | --fixture NAME | --all) "
               "[--stages input,centerline,geometry] [--out DIR] "
               "[--min-width NUMBER|recorded|current] "
               "[--max-width NUMBER|recorded|current] "
               "[--smoothing NUMBER|recorded|current] "
               "[--display-scale NUMBER|recorded|current] "
               "[--invariants-only] [--summary]\n"
               "CSV: optional # pen,min_width,max_width,smoothing,display_scale; "
               "down/move/up,time,x,y[,pressure[,tilt[,orientation]]]; cancel\n";
}

bool parseStages(const std::string& value, replay::StageSelection& stages) {
  stages = {.input = false, .centerline = false, .geometry = false};
  std::stringstream stream(value);
  std::string stage;
  while (std::getline(stream, stage, ',')) {
    if (stage == "input") stages.input = true;
    else if (stage == "centerline") stages.centerline = true;
    else if (stage == "geometry") stages.geometry = true;
    else return false;
  }
  return stages.input || stages.centerline || stages.geometry;
}

bool parseConfigValue(int argc, char** argv, int& index, ConfigValue& value) {
  if (index + 1 >= argc) return false;
  const std::string text = argv[++index];
  if (text == "current") {
    value.source = ConfigSource::Current;
    return true;
  }
  if (text == "recorded") {
    value.source = ConfigSource::Recorded;
    return true;
  }
  try {
    std::size_t parsed = 0;
    const double candidate = std::stod(text, &parsed);
    if (parsed != text.size() || !std::isfinite(candidate)) return false;
    value = {.source = ConfigSource::Value, .value = candidate};
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

bool parseOptions(int argc, char** argv, Options& options) {
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index];
    if (argument == "--input" && index + 1 < argc) options.input = argv[++index];
    else if (argument == "--fixture" && index + 1 < argc) options.fixture = argv[++index];
    else if (argument == "--all") options.all = true;
    else if (argument == "--invariants-only") options.invariantsOnly = true;
    else if (argument == "--summary") options.summary = true;
    else if (argument == "--out" && index + 1 < argc) options.output = argv[++index];
    else if (argument == "--min-width") {
      if (!parseConfigValue(argc, argv, index, options.minWidth)) return false;
    } else if (argument == "--max-width") {
      if (!parseConfigValue(argc, argv, index, options.maxWidth)) return false;
    } else if (argument == "--smoothing") {
      if (!parseConfigValue(argc, argv, index, options.smoothing)) return false;
    } else if (argument == "--display-scale") {
      if (!parseConfigValue(argc, argv, index, options.displayScale)) return false;
    } else if (argument == "--stages" && index + 1 < argc) {
      if (!parseStages(argv[++index], options.stages)) return false;
    } else return false;
  }
  return static_cast<int>(options.input.has_value()) +
      static_cast<int>(options.fixture.has_value()) + static_cast<int>(options.all) == 1;
}

std::vector<replay::Operation> fixtureOperations(const fixtures::Fixture& fixture) {
  std::vector<replay::Operation> result;
  result.reserve(fixture.inputs.size());
  for (const auto& input : fixture.inputs)
    result.push_back({.type = replay::OperationType::Input, .input = input});
  return result;
}

bool load(const std::filesystem::path& path, std::vector<replay::Operation>& operations) {
  std::ifstream input(path);
  if (!input) { std::cerr << "Could not open input: " << path << '\n'; return false; }
  std::string line;
  std::size_t lineNumber = 0;
  while (std::getline(input, line)) {
    ++lineNumber;
    const auto first = line.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) continue;
    if (line[first] == '#' && line.compare(first, 5, "# pen") != 0) continue;
    if (line.compare(first, 6, "event,") == 0) continue;
    replay::Operation operation;
    std::string error;
    if (!replay::parseOperation(line, operation, error)) {
      std::cerr << "Line " << lineNumber << ": " << error << '\n'; return false;
    }
    operations.push_back(operation);
  }
  return true;
}

void applyExplicitConfigValues(const Options& options, StrokeConfig& config) {
  if (options.minWidth.source == ConfigSource::Value)
    config.minWidth = options.minWidth.value;
  if (options.maxWidth.source == ConfigSource::Value)
    config.maxWidth = options.maxWidth.value;
  if (options.smoothing.source == ConfigSource::Value)
    config.smoothing = options.smoothing.value;
  if (options.displayScale.source == ConfigSource::Value)
    config.logicalDisplayUnitsPerPageUnit = options.displayScale.value;
}

bool usesRecordedConfig(const Options& options) {
  return options.minWidth.source == ConfigSource::Recorded ||
      options.maxWidth.source == ConfigSource::Recorded ||
      options.smoothing.source == ConfigSource::Recorded ||
      options.displayScale.source == ConfigSource::Recorded;
}

void applyRecordedConfig(const Options& options, const StrokeConfig& base,
                         const StrokeConfig& recorded, StrokeConfig& target) {
  target = base;
  if (options.minWidth.source == ConfigSource::Recorded)
    target.minWidth = recorded.minWidth;
  if (options.maxWidth.source == ConfigSource::Recorded)
    target.maxWidth = recorded.maxWidth;
  if (options.smoothing.source == ConfigSource::Recorded)
    target.smoothing = recorded.smoothing;
  if (options.displayScale.source == ConfigSource::Recorded)
    target.logicalDisplayUnitsPerPageUnit = recorded.logicalDisplayUnitsPerPageUnit;
}

bool execute(const std::string& name, const std::vector<replay::Operation>& operations,
             const Options& options) {
  StrokeConfig config;
  applyExplicitConfigValues(options, config);
  const bool recordedConfigRequested = usesRecordedConfig(options);

  std::vector<replay::Operation> effectiveOperations;
  effectiveOperations.reserve(operations.size());
  for (const auto& operation : operations) {
    if (operation.type == replay::OperationType::Configure &&
        !recordedConfigRequested) {
      continue;
    }
    auto effectiveOperation = operation;
    if (effectiveOperation.type == replay::OperationType::Configure) {
      const StrokeConfig recordedConfig = effectiveOperation.config;
      applyRecordedConfig(options, config, recordedConfig,
                          effectiveOperation.config);
    }
    effectiveOperations.push_back(effectiveOperation);
  }
  const auto result = replay::run(name, effectiveOperations, options.stages, config);
  for (const auto& failure : result.invariantFailures)
    std::cerr << name << ": " << failure << '\n';
  if (!result.ok()) return false;
  if (!options.invariantsOnly) {
    std::string error;
    if (!replay::writeArtifacts(result, options.output, options.stages, error)) {
      std::cerr << name << ": " << error << '\n'; return false;
    }
  }
  if (options.summary) {
    const auto baseline = replay::measureBaseline(result);
    std::size_t unsupportedEnvelopeCount = 0;
    for (const auto& record : result.records)
      if (record.frameType == StrokeFrameType::Final &&
          record.publishedGeometry.evaluated &&
          record.publishedGeometry.evidence.status ==
              startup::StartupEvidenceStatus::Unsupported)
        ++unsupportedEnvelopeCount;
    std::cout << "PASS name=" << name
              << " operations=" << baseline.inputOperationCount
              << " strokes=" << baseline.strokeCount
              << " outline_segments=" << baseline.outlineSegmentCount
              << " contours=" << baseline.contourCount
              << " max_chord=" << std::setprecision(17)
              << baseline.maximumChordLength
              << " serialized_frame_bytes=" << baseline.serializedFrameBytes
              << " transport_hash=0x" << std::hex << std::setw(16)
              << std::setfill('0') << baseline.transportHash << std::dec
              << std::setfill(' ')
              << " geometry_unsupported="
              << unsupportedEnvelopeCount << '\n';
  } else {
    std::cout << name << ": " << result.records.size()
              << " operations passed\n";
  }
  return true;
}
}  // namespace

int main(int argc, char** argv) {
  Options options;
  if (!parseOptions(argc, argv, options)) { usage(); return 2; }
  if (options.input) {
    std::vector<replay::Operation> operations;
    if (!load(*options.input, operations)) return 2;
    return execute(options.input->stem().string(), operations, options) ? 0 : 1;
  }
  bool found = false;
  bool passed = true;
  for (const auto& fixture : fixtures::all()) {
    if (!options.all && fixture.name != *options.fixture) continue;
    found = true;
    passed = execute(std::string(fixture.name), fixtureOperations(fixture), options) && passed;
  }
  if (!found) { std::cerr << "Unknown fixture: " << *options.fixture << '\n'; return 2; }
  return passed ? 0 : 1;
}
