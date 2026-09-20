#pragma once

#include "primitives/StrokeOutline.hpp"

#include <cstddef>
#include <span>
#include <vector>

namespace margelo::nitro::inksignpdf::startup {

// Phase belongs to the caller's modeled/styling horizon, not to radius == 0.
enum class StartupPhase { Nose, Widening, BodyJoin, Terminal, Contact };

struct StartupSection {
  Vec2 center;
  Vec2 tangent;
  double arclength = 0.0;
  StartupPhase phase = StartupPhase::Widening;
};

enum class StartupEvidenceStatus {
  // This is deliberately NOT "accepted": no claim is made between sections.
  NoViolationAtSections,
  Violation,
  Unsupported,
};

enum class StartupEvidenceReason {
  None,
  InwardSideMovement,
  WidthValley,
  TerminalExpansion,
  InvalidSections,
  InvalidContour,
  AmbiguousCrossSection,
  MissingCenterCoverage,
  InvalidTerminalContact,
  WorkLimit,
};

// Observation at the supplied section, NOT a terminal-policy certificate.
// NonzeroWidth includes a retained nose covering contact and the production
// minimum-radius endpoint. Neither is permission to modify startup radii.
enum class StartupContactObservation {
  NotMeasured,
  ZeroWidthEndpoint,
  NonzeroWidth,
};

struct StartupEnvelopeEvidence {
  StartupEvidenceStatus status = StartupEvidenceStatus::Unsupported;
  StartupEvidenceReason reason = StartupEvidenceReason::None;
  double comparisonTolerance = 0.0;  // Policy tolerance, not a proof/error bound.
  double minimumWidth = 0.0;
  double maximumWidth = 0.0;
  double maximumLeftInward = 0.0;
  double maximumRightInward = 0.0;
  double maximumWidthDrawdown = 0.0;
  double widthValleyDepth = 0.0;
  StartupContactObservation contact = StartupContactObservation::NotMeasured;
  double contactWidth = 0.0;
  std::size_t sectionsEvaluated = 0;
  std::size_t segmentsVisited = 0;
};

struct StartupEvidenceLimits {
  std::size_t maxSections = 256;
  std::size_t maxContours = 64;
  std::size_t maxSegments = 4096;
};

struct StartupEnvelopeConfig {
  double geometryEpsilon = 1e-6;
  double arcTolerance = 1e-3;
};

// Synchronous owner-local diagnostic evaluator. Takes the ACTUAL published
// closed contours, never rebuilds tips or a second outline. Copies own
// independent scratch. Limits bound this evaluation,
// not the future solver's modeled startup horizon.
// Contact measures actual coverage; it does not require exposed zero width.
// The caller must establish authoritative contact/phase provenance separately.
class StartupEnvelopeEvaluator {
 public:
  explicit StartupEnvelopeEvaluator(
      StartupEnvelopeConfig geometry = {},
      StartupEvidenceLimits limits = {});

  StartupEnvelopeEvidence evaluate(
      std::span<const StrokeContour> contours,
      std::span<const StartupSection> sections);

 private:
  struct Crossing { double lateral; int windingDelta; };
  struct Interval { double low; double high; };

  StartupEvidenceReason measureSection(
      std::span<const StrokeContour> contours,
      const StartupSection& section, double& left, double& right,
      StartupEnvelopeEvidence& evidence);

  StartupEnvelopeConfig geometry_;
  StartupEvidenceLimits limits_;
  std::vector<Crossing> crossings_;
  std::vector<Interval> intervals_;
};

}  // namespace margelo::nitro::inksignpdf::startup
