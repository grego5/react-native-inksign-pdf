#include "ink-engine/replay-tool/StrokeReplayInternal.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string_view>
#include <vector>

namespace margelo::nitro::inksignpdf::replay::detail {
namespace {

void appendSegmentSvg(std::ostringstream& output,
                      const CubicSegment& segment,
                      double minX, double minY, double margin) {
  auto point = [&](const Vec2 value) {
    output << value.x - minX + margin << ' ' << value.y - minY + margin;
  };
  output << " C "; point(segment.c1); output << ' ';
  point(segment.c2); output << ' ';
  point(segment.p3);
}

std::string svgPath(const StrokeContour& contour, double minX,
                    double minY, double margin) {
  const auto& segments = contour.path.segments;
  if (segments.empty()) return {};
  std::ostringstream output;
  auto point = [&](const Vec2 value) {
    output << value.x - minX + margin << ' ' << value.y - minY + margin;
  };
  output << std::setprecision(9) << "M "; point(segments.front().p0);
  for (const auto& segment : segments)
    appendSegmentSvg(output, segment, minX, minY, margin);
  if (contour.path.closed) output << " Z";
  return output.str();
}

std::string svgPath(const std::vector<Vec2>& points, double minX,
                    double minY, double margin, bool close) {
  if (points.empty()) return {};
  std::ostringstream output;
  output << std::setprecision(9) << "M " << points.front().x - minX + margin
         << ' ' << points.front().y - minY + margin;
  for (std::size_t index = 1; index < points.size(); ++index)
    output << " L " << points[index].x - minX + margin << ' '
           << points[index].y - minY + margin;
  if (close) output << " Z";
  return output.str();
}

}  // namespace

bool writeSvgArtifacts(const Result& result,
                       const std::filesystem::path& directory,
                       StageSelection stages, std::string& error) {
  auto open = [&](std::string_view suffix, std::ofstream& output) {
    output.open(directory / (result.name + std::string(suffix)),
                std::ios::binary);
    if (!output) error = "could not open output artifact";
    return static_cast<bool>(output);
  };

  std::vector<Vec2> inputPoints;
  std::vector<Vec2> centerline;
  std::vector<StrokeContour> outlines;
  for (const Record& record : result.records) {
    if (!record.inputs.empty()) {
      inputPoints.clear();
      for (const auto& input : record.inputs) inputPoints.push_back(input.position);
    }
    if (!record.centerline.empty()) {
      centerline.clear();
      for (const auto& point : record.centerline) centerline.push_back(point.point);
    }
    if (record.frameType == InkStrokeFrameType::Final)
      for (const auto& contour : record.geometry)
        if (!contour.path.segments.empty()) outlines.push_back(contour);
  }

  double minX = std::numeric_limits<double>::infinity();
  double minY = minX;
  double maxX = -minX;
  double maxY = -minX;
  auto include = [&](const std::vector<Vec2>& points) {
    for (const Vec2 point : points) {
      minX = std::min(minX, point.x); minY = std::min(minY, point.y);
      maxX = std::max(maxX, point.x); maxY = std::max(maxY, point.y);
    }
  };
  auto includeContour = [&](const StrokeContour& contour) {
    for (const auto& segment : contour.path.segments)
      include({segment.p0, segment.c1, segment.c2, segment.p3});
  };
  include(inputPoints); include(centerline);
  for (const auto& outline : outlines) includeContour(outline);
  if (!std::isfinite(minX)) minX = minY = 0.0, maxX = maxY = 100.0;
  constexpr double margin = 16.0;
  std::ofstream svg;
  if (!open("-layers.svg", svg)) return false;
  svg << "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 "
      << maxX - minX + margin * 2 << ' ' << maxY - minY + margin * 2 << "\">\n"
      << "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n";
  if (stages.geometry) for (const auto& outline : outlines)
    svg << "<path d=\"" << svgPath(outline, minX, minY, margin)
        << "\" fill=\"#dbeafe\" stroke=\"#2563eb\"/>\n";
  if (stages.input && !inputPoints.empty())
    svg << "<path d=\"" << svgPath(inputPoints, minX, minY, margin, false)
        << "\" fill=\"none\" stroke=\"#dc2626\" stroke-dasharray=\"3 2\"/>\n";
  if (stages.centerline && !centerline.empty())
    svg << "<path d=\"" << svgPath(centerline, minX, minY, margin, false)
        << "\" fill=\"none\" stroke=\"#111827\"/>\n";
  svg << "</svg>\n";

  auto writeFrameSvg = [&](const Record& record, std::string_view stage,
                           bool zoomed) {
    if (record.geometry.empty()) return true;
    double frameMinX = std::numeric_limits<double>::infinity();
    double frameMinY = frameMinX;
    double frameMaxX = -frameMinX;
    double frameMaxY = -frameMinX;
    auto frameInclude = [&](Vec2 point) {
      frameMinX = std::min(frameMinX, point.x);
      frameMinY = std::min(frameMinY, point.y);
      frameMaxX = std::max(frameMaxX, point.x);
      frameMaxY = std::max(frameMaxY, point.y);
    };
    for (const auto& contour : record.geometry)
      for (const auto& segment : contour.path.segments)
        for (const Vec2 point : {segment.p0, segment.c1, segment.c2, segment.p3})
          frameInclude(point);
    for (const auto& point : record.centerline) frameInclude(point.point);
    if (!std::isfinite(frameMinX)) return true;
    const double fullWidth = std::max(frameMaxX - frameMinX, 1.0);
    const double fullHeight = std::max(frameMaxY - frameMinY, 1.0);
    double viewMinX = frameMinX;
    double viewMinY = frameMinY;
    double viewWidth = fullWidth;
    double viewHeight = fullHeight;
    if (zoomed && !record.envelopeSections.empty()) {
      const Vec2 focus = record.envelopeSections.front().center;
      viewWidth = std::max(fullWidth / 6.0, 8.0);
      viewHeight = std::max(fullHeight / 6.0, 8.0);
      viewMinX = focus.x - viewWidth * 0.25;
      viewMinY = focus.y - viewHeight * 0.5;
    }
    std::string suffix = "-stroke-" + std::to_string(record.stroke) + "-" +
        std::string(stage) + "-op-" + std::to_string(record.operation);
    if (zoomed) suffix += "-zoom";
    suffix += ".svg";
    std::ofstream frame;
    if (!open(suffix, frame)) return false;
    frame << "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 "
          << viewWidth + margin * 2 << ' ' << viewHeight + margin * 2 << "\">\n"
          << "<title>stroke=" << record.stroke << " operation="
          << record.operation << " stage=" << stage << "</title>\n"
          << "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n";
    for (const auto& contour : record.geometry)
      frame << "<path d=\"" << svgPath(contour, viewMinX, viewMinY, margin)
            << "\" fill=\"#dbeafe\" stroke=\"#2563eb\"/>\n";
    if (!record.centerline.empty()) {
      std::vector<Vec2> points;
      points.reserve(record.centerline.size());
      for (const auto& point : record.centerline) points.push_back(point.point);
      frame << "<path d=\"" << svgPath(points, viewMinX, viewMinY, margin, false)
            << "\" fill=\"none\" stroke=\"#111827\"/>\n";
    }
    for (const auto& section : record.envelopeSections)
      frame << "<circle cx=\"" << section.center.x - viewMinX + margin
            << "\" cy=\"" << section.center.y - viewMinY + margin
            << "\" r=\"1\" fill=\"#dc2626\"/>\n";
    frame << "</svg>\n";
    return true;
  };

  if (!stages.geometry) return true;
  for (const Record& finalRecord : result.records) {
    if (finalRecord.frameType != InkStrokeFrameType::Final ||
        finalRecord.stroke == 0)
      continue;
    const Record* firstMovingFrame = nullptr;
    const Record* lastNonterminalFrame = nullptr;
    for (const Record& record : result.records) {
      if (record.stroke != finalRecord.stroke || record.geometry.empty()) continue;
      if (record.frameType != InkStrokeFrameType::Final &&
          firstMovingFrame == nullptr && hasRealMovingDiagnostic(record))
        firstMovingFrame = &record;
      if (record.frameType != InkStrokeFrameType::Final &&
          hasRealMovingDiagnostic(record))
        lastNonterminalFrame = &record;
    }
    if (firstMovingFrame != nullptr &&
        (!writeFrameSvg(*firstMovingFrame, "first-moving", false) ||
         !writeFrameSvg(*firstMovingFrame, "first-moving", true))) return false;
    if (lastNonterminalFrame != nullptr &&
        (!writeFrameSvg(*lastNonterminalFrame, "last-nonterminal", false) ||
         !writeFrameSvg(*lastNonterminalFrame, "last-nonterminal", true))) return false;
    if (!writeFrameSvg(finalRecord, "final", false) ||
        !writeFrameSvg(finalRecord, "final", true)) return false;
  }
  return true;
}

}  // namespace margelo::nitro::inksignpdf::replay::detail
