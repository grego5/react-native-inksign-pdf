#include "replay/StrokeReplayInternal.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <utility>
#include <vector>

namespace margelo::nitro::inksignpdf::replay::detail {
namespace {

constexpr std::uint64_t kFnvOffsetBasis = 1469598103934665603ULL;
constexpr std::uint64_t kFnvPrime = 1099511628211ULL;

void appendLittleEndian(std::vector<std::uint8_t>& bytes, std::uint64_t value) {
  for (std::size_t index = 0; index < sizeof(value); ++index)
    bytes.push_back(static_cast<std::uint8_t>(value >> (index * 8)));
}

void appendDouble(std::vector<std::uint8_t>& bytes, double value) {
  appendLittleEndian(bytes, std::bit_cast<std::uint64_t>(value));
}

void appendPoint(std::vector<std::uint8_t>& bytes, Vec2 point) {
  appendDouble(bytes, point.x);
  appendDouble(bytes, point.y);
}

void appendCanonicalFrame(std::vector<std::uint8_t>& bytes,
                          const Record& record) {
  // This is the logical C frame transport layout, with fixed-width fields so
  // the contract does not depend on host ABI padding or size_t width.
  appendLittleEndian(bytes, static_cast<std::uint64_t>(record.frameType));
  appendLittleEndian(bytes, record.revision);
  appendLittleEndian(bytes, record.committedPointCount);
  std::size_t segmentCount = 0;
  for (const auto& contour : record.geometry)
    segmentCount += contour.path.segments.size();
  appendLittleEndian(bytes, segmentCount);
  appendLittleEndian(bytes, record.geometry.size());
  for (const auto& contour : record.geometry) {
    for (const auto& segment : contour.path.segments) {
      appendPoint(bytes, segment.p0);
      appendPoint(bytes, segment.c1);
      appendPoint(bytes, segment.c2);
      appendPoint(bytes, segment.p3);
      appendLittleEndian(bytes, segment.sourceStart);
      appendLittleEndian(bytes, segment.sourceEnd);
    }
  }
  for (const auto& contour : record.geometry) {
    std::size_t contourSegments = contour.path.segments.size();
    appendLittleEndian(bytes, contourSegments);
    appendLittleEndian(bytes, contour.sourceStart);
    appendLittleEndian(bytes, contour.sourceEnd);
    appendLittleEndian(bytes, contour.path.closed ? 1 : 0);
  }
}

bool finite(Vec2 point) {
  return std::isfinite(point.x) && std::isfinite(point.y);
}

Vec2 cubicPoint(const CubicSegment& segment, double t) {
  const double one = 1.0 - t;
  return {
      one * one * one * segment.p0.x + 3.0 * one * one * t * segment.c1.x +
          3.0 * one * t * t * segment.c2.x + t * t * t * segment.p3.x,
      one * one * one * segment.p0.y + 3.0 * one * one * t * segment.c1.y +
          3.0 * one * t * t * segment.c2.y + t * t * t * segment.p3.y};
}

std::optional<double> independentlySampleWidth(
    const StrokeContourCollection& contours,
    const startup::StartupSection& section) {
  const double tangentLength = std::hypot(section.tangent.x, section.tangent.y);
  if (!(tangentLength > 0.0) || !std::isfinite(tangentLength)) return std::nullopt;
  const Vec2 tangent{section.tangent.x / tangentLength,
                     section.tangent.y / tangentLength};
  const Vec2 normal{-tangent.y, tangent.x};
  std::vector<std::pair<double, int>> crossings;
  std::vector<std::pair<double, double>> intervals;
  constexpr std::size_t kSamplesPerCubic = 256;
  for (const auto& contour : contours) {
    crossings.clear();
    for (const auto& segment : contour.path.segments) {
      Vec2 previous = cubicPoint(segment, 0.0);
      double previousLongitudinal =
          (previous.x - section.center.x) * tangent.x +
          (previous.y - section.center.y) * tangent.y;
      for (std::size_t i = 1; i <= kSamplesPerCubic; ++i) {
        const double amount = static_cast<double>(i) /
            static_cast<double>(kSamplesPerCubic);
        const Vec2 current = cubicPoint(segment, amount);
        const double longitudinal =
            (current.x - section.center.x) * tangent.x +
            (current.y - section.center.y) * tangent.y;
        const bool increasing = previousLongitudinal <= 0.0 &&
            longitudinal > 0.0;
        const bool decreasing = longitudinal <= 0.0 &&
            previousLongitudinal > 0.0;
        if (increasing || decreasing) {
          const double denominator = longitudinal - previousLongitudinal;
          if (denominator == 0.0) return std::nullopt;
          const double fraction =
              std::clamp(-previousLongitudinal / denominator, 0.0, 1.0);
          const Vec2 crossing = {
              previous.x + fraction * (current.x - previous.x),
              previous.y + fraction * (current.y - previous.y)};
          const double lateral =
              (crossing.x - section.center.x) * normal.x +
              (crossing.y - section.center.y) * normal.y;
          if (!std::isfinite(lateral)) return std::nullopt;
          crossings.emplace_back(lateral, increasing ? 1 : -1);
        }
        previous = current;
        previousLongitudinal = longitudinal;
      }
    }
  if (crossings.empty()) continue;
  std::sort(crossings.begin(), crossings.end());
  int winding = 0;
  double start = 0.0;
  for (std::size_t i = 0; i < crossings.size();) {
    const double lateral = crossings[i].first;
    int delta = 0;
    do {
      delta += crossings[i++].second;
    } while (i < crossings.size() &&
             std::abs(crossings[i].first - lateral) <= 1e-6);
    const int next = winding + delta;
    if (winding == 0 && next != 0) start = lateral;
    if (winding != 0 && next == 0) intervals.emplace_back(start, lateral);
    winding = next;
  }
  if (winding != 0) return std::nullopt;
  }
  // Production fills contours independently. Opposite winding in overlapping
  // chunks must not cancel; union the per-contour filled intervals instead.
  if (intervals.empty()) return std::nullopt;
  std::sort(intervals.begin(), intervals.end());
  double low = intervals.front().first;
  double high = intervals.front().second;
  for (std::size_t i = 1; i < intervals.size(); ++i) {
    if (intervals[i].first > high + 1e-6) return std::nullopt;
    high = std::max(high, intervals[i].second);
  }
  if (low > 1e-6 || high < -1e-6) return std::nullopt;
  return std::max(0.0, high) + std::max(0.0, -low);
}

}  // namespace

PublishedGeometryMetrics measurePublishedGeometry(const Record& record) {
  PublishedGeometryMetrics metrics;
  if (record.geometry.empty() || record.envelopeSections.empty()) return metrics;
  startup::StartupEnvelopeEvaluator evaluator;
  metrics.evidence = evaluator.evaluate(record.geometry, record.envelopeSections);
  metrics.evaluated = true;
  // Section phase provenance belongs to production styling and is deliberately
  // absent here. These metrics remain unevaluated; the evaluator only reports
  // measured width evidence at sampled modeled centers.

  constexpr std::size_t kSamplesPerCubic = 64;
  for (const auto& contour : record.geometry) {
    for (const auto& segment : contour.path.segments) {
      for (std::size_t i = 0; i <= kSamplesPerCubic; ++i) {
        const Vec2 point = cubicPoint(segment,
            static_cast<double>(i) / static_cast<double>(kSamplesPerCubic));
        ++metrics.sampledCubicPoints;
        if (!finite(point)) ++metrics.sampledCubicFailures;
      }
    }
  }
  // Measure every section independently, including when aggregate topology is
  // unsupported. Never compare only global extrema or call missing data a pass.
  for (const auto& section : record.envelopeSections) {
    SectionWidthCrossCheck check;
    const auto sampled = independentlySampleWidth(record.geometry, section);
    const auto measured = evaluator.evaluate(record.geometry, std::span(&section, 1));
    if (sampled) check.sampledWidth = *sampled;
    if (measured.status != startup::StartupEvidenceStatus::Unsupported)
      check.evaluatorWidth = measured.minimumWidth;
    if (sampled && std::isfinite(check.evaluatorWidth)) {
      const double error = std::abs(*sampled - check.evaluatorWidth);
      if (metrics.sampledSectionsCompared++ == 0)
        metrics.sampledWidthMaximumError = error;
      else metrics.sampledWidthMaximumError = std::max(metrics.sampledWidthMaximumError, error);
      check.status = error > 0.05 ? WidthCrossCheckStatus::Disagreement
                                 : WidthCrossCheckStatus::Agreement;
      if (check.status == WidthCrossCheckStatus::Disagreement)
        ++metrics.sampledWidthDisagreements;
    } else {
      ++metrics.sampledSectionFailures;
    }
    metrics.sectionWidths.push_back(check);
  }
  metrics.widthCrossCheck = metrics.sampledWidthDisagreements != 0
      ? WidthCrossCheckStatus::Disagreement
      : metrics.sampledSectionFailures != 0 ? WidthCrossCheckStatus::Unsupported
      : WidthCrossCheckStatus::Agreement;
  return metrics;
}

std::vector<startup::StartupSection> buildEnvelopeSections(
    const std::vector<ModeledPoint>& centerline) {
  constexpr std::size_t kMaxSections = 256;
  std::vector<startup::StartupSection> sections;
  const std::size_t count = std::min(centerline.size(), kMaxSections);
  sections.reserve(count);
  for (std::size_t sample = 0; sample < count; ++sample) {
    const std::size_t index = centerline.size() <= kMaxSections
        ? sample
        : sample * (centerline.size() - 1) / (kMaxSections - 1);
    Vec2 tangent = centerline[index].tangent;
    if (!finite(tangent) || std::hypot(tangent.x, tangent.y) <= 1e-12) {
      if (index == 0 && centerline.size() > 1)
        tangent = {centerline[1].point.x - centerline[0].point.x,
                   centerline[1].point.y - centerline[0].point.y};
      else if (index > 0)
        tangent = {centerline[index].point.x - centerline[index - 1].point.x,
                   centerline[index].point.y - centerline[index - 1].point.y};
    }
    if (!finite(tangent) || std::hypot(tangent.x, tangent.y) <= 1e-12) continue;
    sections.push_back({.center = centerline[index].point,
                        .tangent = tangent,
                        .arclength = centerline[index].runningLength,
                        .phase = startup::StartupPhase::Widening});
  }
  return sections;
}

bool hasRealMovingDiagnostic(const Record& record) {
  return std::any_of(record.diagnostics.begin(), record.diagnostics.end(),
                     [](const StrokeDiagnosticSample& sample) {
                       return sample.real && !sample.predicted &&
                           sample.segmentDistance > 0.0;
                     });
}

BaselineMetrics measureBaseline(const Result& result) {
  BaselineMetrics metrics;
  std::vector<std::uint8_t> serializedFrames;
  bool haveStartRadius = false;
  for (std::size_t recordIndex = 0; recordIndex < result.records.size();
       ++recordIndex) {
    const Record& record = result.records[recordIndex];
    if (record.event == "down" || record.event == "move" ||
        record.event == "up")
      ++metrics.inputOperationCount;
    for (const ModeledPoint& point : record.centerline)
      metrics.maximumRadius = std::max(metrics.maximumRadius, point.radius);
    if (record.frameType == StrokeFrameType::Final) {
      ++metrics.strokeCount;
      metrics.committedPointCount += record.committedPointCount;
      metrics.contourCount += record.geometry.size();
      for (const auto& contour : record.geometry)
        for (const auto& segment : contour.path.segments) {
          ++metrics.outlineSegmentCount;
          metrics.maximumChordLength = std::max(
              metrics.maximumChordLength,
              std::hypot(segment.p3.x - segment.p0.x,
                         segment.p3.y - segment.p0.y));
        }
      appendCanonicalFrame(serializedFrames, record);
      if (!record.centerline.empty()) {
        const double radius = record.centerline.front().radius;
        if (!haveStartRadius) {
          metrics.minimumStartRadius = metrics.maximumStartRadius = radius;
          haveStartRadius = true;
        } else {
          metrics.minimumStartRadius = std::min(metrics.minimumStartRadius, radius);
          metrics.maximumStartRadius = std::max(metrics.maximumStartRadius, radius);
        }
      }
    }
  }
  metrics.serializedFrameBytes = serializedFrames.size();
  metrics.transportHash = kFnvOffsetBasis;
  for (const std::uint8_t byte : serializedFrames)
    metrics.transportHash = (metrics.transportHash ^ byte) * kFnvPrime;
  return metrics;
}

bool validateStartupDiagnostics(const Result& result, std::string& error) {
  for (const Record& record : result.records) {
    if (record.frameType != StrokeFrameType::Final ||
        record.diagnostics.empty())
      continue;
    const auto& samples = record.diagnostics;
    std::size_t previousModeledFrontier = 0;
    std::size_t previousContourFrontier = 0;
    for (const auto& sample : samples) {
      if (sample.fixedCenterlineFrontier < previousModeledFrontier ||
          sample.contourSourceEnd < previousContourFrontier) {
        error = "published envelope frontier moved backwards";
        return false;
      }
      previousModeledFrontier = sample.fixedCenterlineFrontier;
      previousContourFrontier = sample.contourSourceEnd;
    }
  }
  return true;
}

}  // namespace margelo::nitro::inksignpdf::replay::detail
