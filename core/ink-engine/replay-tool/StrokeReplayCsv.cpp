#include "ink-engine/replay-tool/StrokeReplayInternal.hpp"

#include <algorithm>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string_view>

namespace margelo::nitro::inksignpdf::replay::detail {
namespace {

const char* frameName(InkStrokeFrameType type) {
  switch (type) {
    case InkStrokeFrameType::Committed: return "committed";
    case InkStrokeFrameType::Prediction: return "prediction";
    case InkStrokeFrameType::Final: return "final";
  }
  return "unknown";
}

const char* evidenceStatusName(startup::StartupEvidenceStatus status) {
  switch (status) {
    case startup::StartupEvidenceStatus::NoViolationAtSections: return "no_violation_at_sections";
    case startup::StartupEvidenceStatus::Violation: return "violation";
    case startup::StartupEvidenceStatus::Unsupported: return "unsupported";
  }
  return "unknown";
}

const char* evidenceReasonName(startup::StartupEvidenceReason reason) {
  switch (reason) {
    case startup::StartupEvidenceReason::None: return "none";
    case startup::StartupEvidenceReason::InwardSideMovement: return "inward_side_movement";
    case startup::StartupEvidenceReason::WidthValley: return "width_valley";
    case startup::StartupEvidenceReason::TerminalExpansion: return "terminal_expansion";
    case startup::StartupEvidenceReason::InvalidSections: return "invalid_sections";
    case startup::StartupEvidenceReason::InvalidContour: return "invalid_contour";
    case startup::StartupEvidenceReason::AmbiguousCrossSection: return "ambiguous_cross_section";
    case startup::StartupEvidenceReason::MissingCenterCoverage: return "missing_center_coverage";
    case startup::StartupEvidenceReason::InvalidTerminalContact: return "invalid_terminal_contact";
    case startup::StartupEvidenceReason::WorkLimit: return "work_limit";
  }
  return "unknown";
}

const char* contactObservationName(startup::StartupContactObservation observation) {
  switch (observation) {
    case startup::StartupContactObservation::NotMeasured: return "not_measured";
    case startup::StartupContactObservation::ZeroWidthEndpoint: return "zero_width_endpoint";
    case startup::StartupContactObservation::NonzeroWidth: return "nonzero_width";
  }
  return "unknown";
}

}  // namespace

bool writeCsvArtifacts(const Result& result,
                       const std::filesystem::path& directory,
                       StageSelection stages, std::string& error) {
  auto open = [&](std::string_view suffix, std::ofstream& output) {
    output.open(directory / (result.name + std::string(suffix)), std::ios::binary);
    if (!output) error = "could not open output artifact";
    return static_cast<bool>(output);
  };
  if (stages.input) {
    std::ofstream output;
    if (!open("-input.csv", output)) return false;
    output << "operation,event,index,time,x,y,pressure,tilt,orientation\n";
    for (const Record& record : result.records)
      for (std::size_t i = 0; i < record.inputs.size(); ++i) {
        const auto& value = record.inputs[i];
        output << record.operation << ',' << record.event << ',' << i << ','
               << std::setprecision(17) << value.time << ',' << value.position.x << ','
               << value.position.y << ',' << value.pressure << ',' << value.tilt << ','
               << value.orientation << '\n';
      }
  }
  if (stages.centerline) {
    std::ofstream output;
    if (!open("-centerline.csv", output)) return false;
    output << "operation,event,frame,revision,index,type,time,x,y,distance,velocity,acceleration_x,acceleration_y,pressure,radius\n";
    for (const Record& record : result.records)
      for (std::size_t i = 0; i < record.centerline.size(); ++i) {
        const auto& value = record.centerline[i];
        output << record.operation << ',' << record.event << ',' << frameName(record.frameType)
               << ',' << record.revision << ',' << i << ",committed," << std::setprecision(17)
               << value.time << ',' << value.point.x << ',' << value.point.y << ','
               << value.distance << ',' << value.velocity << ',' << value.acceleration.x << ','
               << value.acceleration.y << ',' << value.pressure << ',' << value.radius << '\n';
      }
  }
  if (stages.centerline) {
    std::ofstream output;
    if (!open("-diagnostics.csv", output)) return false;
    output << "# schema=stroke-diagnostics-v11; units=page,seconds,display-units,display-units-per-second,display-units-per-second-squared\n";
    output << "operation,event,frame,modeled_index,raw_source_index,modeled_source_index,time,page_x,page_y,running_length_page,running_length_display,velocity_x_page_per_s,velocity_y_page_per_s,display_speed,normalized_speed,acceleration_x_page_per_s2,acceleration_y_page_per_s2,forward_acceleration_page_per_s2,lateral_acceleration_page_per_s2,forward_acceleration_display_per_s2,lateral_acceleration_display_per_s2,dt_seconds,turn_factor,effective_speed_display,target_radius_page,radius_page,segment_distance_page,response_distance_page,response_alpha,final_radius_page,stable,fixed_centerline_frontier,contour_source_start,contour_source_end,real,predicted\n";
    for (const Record& record : result.records) {
      if (record.frameType != InkStrokeFrameType::Final) continue;
      for (const auto& value : record.diagnostics) {
        output << std::setprecision(17) << record.operation << ',' << record.event << ','
          << frameName(record.frameType) << ',' << value.modeledIndex << ',' << value.rawSourceIndex << ','
          << value.modeledSourceIndex << ',' << value.time << ',' << value.position.x << ',' << value.position.y << ','
          << value.runningLength << ',' << value.runningLengthDisplay << ',' << value.velocity.x << ','
          << value.velocity.y << ',' << value.displaySpeed << ',' << value.normalizedSpeed << ','
          << value.acceleration.x << ',' << value.acceleration.y << ',' << value.forwardAcceleration << ','
          << value.lateralAcceleration << ',' << value.forwardAccelerationDisplay << ',' << value.lateralAccelerationDisplay << ','
          << value.dtSeconds << ',' << value.turnFactor << ','
          << value.effectiveSpeedDisplay << ',' << value.targetRadius << ','
          << value.radius << ',' << value.segmentDistance << ','
          << value.responseDistancePage << ','
          << value.responseAlpha << ',' << value.finalRadius << ',' << (value.stable ? 1 : 0) << ','
          << value.fixedCenterlineFrontier << ','
          << value.contourSourceStart << ',' << value.contourSourceEnd << ',' << (value.real ? 1 : 0) << ','
          << (value.predicted ? 1 : 0) << '\n';
      }
    }
  }

  if (stages.centerline) {
    std::ofstream startup;
    if (!open("-envelope.csv", startup)) return false;
    startup << "# schema=stroke-envelope-v1; sampled_sections_only=true; continuous_certification=not_claimed\n";
    startup << "operation,stroke,has_moving_diagnostic,evidence_status,evidence_reason,min_width,max_width,maximum_left_inward,maximum_right_inward,width_valley_depth,shoulder_section,shoulder_arclength,body_join_section,body_join_arclength,terminal_section,terminal_arclength,forward_order_violations,sampled_cubic_points,sampled_cubic_failures,sampled_section_failures,sampled_width_disagreements,sampled_width_max_error,contact_observation,contact_width,width_cross_check,sections_compared\n";
    for (const Record& record : result.records) {
      if (record.frameType != InkStrokeFrameType::Final) continue;
      const auto& geometry = record.publishedGeometry;
      const auto& evidence = geometry.evidence;
      startup << std::setprecision(17) << record.operation << ',' << record.stroke << ','
              << (std::any_of(record.diagnostics.begin(), record.diagnostics.end(),
                              [](const auto& sample) {
                                return sample.real && !sample.predicted &&
                                    sample.segmentDistance > 0.0;
                              }) ? 1 : 0) << ','
              << (geometry.evaluated ? evidenceStatusName(evidence.status) : "not_evaluated") << ','
              << (geometry.evaluated ? evidenceReasonName(evidence.reason) : "not_evaluated") << ','
              << (geometry.evaluated ? evidence.minimumWidth : std::numeric_limits<double>::quiet_NaN()) << ','
              << (geometry.evaluated ? evidence.maximumWidth : std::numeric_limits<double>::quiet_NaN()) << ','
              << (geometry.evaluated ? evidence.maximumLeftInward : std::numeric_limits<double>::quiet_NaN()) << ','
              << (geometry.evaluated ? evidence.maximumRightInward : std::numeric_limits<double>::quiet_NaN()) << ','
              << (geometry.evaluated ? evidence.widthValleyDepth : std::numeric_limits<double>::quiet_NaN()) << ','
              << (geometry.shoulderSection == std::numeric_limits<std::size_t>::max() ? -1 : static_cast<long long>(geometry.shoulderSection)) << ','
              << geometry.shoulderArclength << ','
              << (geometry.bodyJoinSection == std::numeric_limits<std::size_t>::max() ? -1 : static_cast<long long>(geometry.bodyJoinSection)) << ','
              << geometry.bodyJoinArclength << ','
              << (geometry.terminalSection == std::numeric_limits<std::size_t>::max() ? -1 : static_cast<long long>(geometry.terminalSection)) << ','
              << geometry.terminalArclength << ','
              << (geometry.forwardOrderEvaluated ? std::to_string(geometry.forwardOrderViolations) : std::string("not_evaluated")) << ','
              << geometry.sampledCubicPoints << ',' << geometry.sampledCubicFailures << ','
              << geometry.sampledSectionFailures << ',' << geometry.sampledWidthDisagreements << ','
              << geometry.sampledWidthMaximumError << ','
              << (geometry.evaluated ? contactObservationName(evidence.contact) : "not_evaluated") << ','
              << (geometry.evaluated ? evidence.contactWidth : std::numeric_limits<double>::quiet_NaN()) << ','
              << (geometry.widthCrossCheck == WidthCrossCheckStatus::NotEvaluated ? "not_evaluated"
                  : geometry.widthCrossCheck == WidthCrossCheckStatus::Unsupported ? "unsupported"
                  : geometry.widthCrossCheck == WidthCrossCheckStatus::Disagreement ? "disagreement"
                  : "agreement") << ',' << geometry.sampledSectionsCompared << '\n';
    }
  }
  if (stages.centerline) {
    std::ofstream terminal;
    if (!open("-terminal.csv", terminal)) return false;
    terminal << "# schema=stroke-terminal-v2; distances=page units; radii=page units\n";
    terminal << "operation,stroke,last_valid_moving_speed,normalized_terminal_speed,selected_taper_distance,remaining_arclength,taper_multiplier,tapered_radius,exact_contact,crossing_remaining_at_0_75,crossing_remaining_at_0_50,crossing_remaining_at_0_25\n";
    for (const Record& record : result.records) if (record.frameType == InkStrokeFrameType::Final && record.terminal.valid) {
      const auto& value = record.terminal;
      auto crossing = [&](double fraction) {
        double remaining = -1.0;
        for (const auto& sample : record.diagnostics)
          if (sample.radius > 0.0 && sample.finalRadius / sample.radius <= fraction)
            remaining = std::max(remaining, std::max(0.0, record.diagnostics.back().runningLength - sample.runningLength));
        return remaining;
      };
      terminal << std::setprecision(17) << record.operation << ',' << record.stroke << ','
               << value.lastValidMovingSpeed << ',' << value.normalizedTerminalSpeed << ','
               << value.selectedTaperDistance << ',' << value.remainingArclength << ','
               << value.taperMultiplier << ',' << value.taperedRadius << ',' << (value.exactContact ? 1 : 0) << ','
               << crossing(0.75) << ',' << crossing(0.50) << ',' << crossing(0.25) << '\n';
    }
  }
  if (stages.centerline) {
    const BaselineMetrics metrics = detail::measureBaseline(result);
    std::ofstream output;
    if (!open("-baseline.csv", output)) return false;
    output << "input_operations,committed_points,outline_segments,strokes,maximum_radius,minimum_start_radius,maximum_start_radius\n"
           << metrics.inputOperationCount << ',' << metrics.committedPointCount << ','
           << metrics.outlineSegmentCount << ',' << metrics.strokeCount << ',' << std::setprecision(17)
           << metrics.maximumRadius << ',' << metrics.minimumStartRadius << ',' << metrics.maximumStartRadius << '\n';
  }
  if (stages.geometry) {
    std::ofstream output;
    if (!open("-geometry.csv", output)) return false;
    output << "operation,event,path,segment,p0x,p0y,c1x,c1y,c2x,c2y,p3x,p3y,source_start,source_end\n";
    for (const Record& record : result.records) {
      if (record.frameType != InkStrokeFrameType::Final) continue;
      for (std::size_t contourIndex = 0; contourIndex < record.geometry.size(); ++contourIndex)
        for (std::size_t i = 0; i < record.geometry[contourIndex].path.segments.size(); ++i) {
          const auto& s = record.geometry[contourIndex].path.segments[i];
          output << record.operation << ',' << record.event << ",contour_" << contourIndex << ',' << i << ','
                 << std::setprecision(17) << s.p0.x << ',' << s.p0.y << ',' << s.c1.x << ',' << s.c1.y << ','
                 << s.c2.x << ',' << s.c2.y << ',' << s.p3.x << ',' << s.p3.y << ','
                 << s.sourceStart << ',' << s.sourceEnd << '\n';
        }
    }
  }
  return true;
}

}  // namespace margelo::nitro::inksignpdf::replay::detail
