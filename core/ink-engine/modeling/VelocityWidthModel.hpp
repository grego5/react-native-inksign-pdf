#pragma once

#include "input/InputNormalizer.hpp"
#include "modeling/SignatureStrokeStyle.hpp"

#include <cstddef>

namespace margelo::nitro::inksignpdf::detail {

struct VelocityWidthPoint {
  NormalizedInput input;
  double dtSeconds = 0.0;
  double turnFactor = 1.0;
  double effectiveSpeedDisplay = 0.0;
  double targetRadius = 0.0;
  double segmentDistance = 0.0;
  double responseDistancePage = 0.0;
  double responseAlpha = 0.0;
  double radius = 0.0;
};

// Owns the stateful page-space radius recurrence. Taper and outline
// construction are owned by SignatureStrokeStyle and geometry stages.
class VelocityWidthModel {
 public:
  struct Snapshot {
    double radiusPage = 0.0;
    Vec2 previousPositionPage;
    Vec2 previousVelocityPage;
    double previousTimeSeconds = 0.0;
    bool initialized = false;
  };

  explicit VelocityWidthModel(const SignatureStrokeStyle& style);

  VelocityWidthPoint begin(const NormalizedInput& input, Vec2 velocity);
  VelocityWidthPoint dot(const NormalizedInput& input, double radius) const;
  VelocityWidthPoint update(const NormalizedInput& input, Vec2 velocity);
  void cancel();

  Snapshot snapshot() const noexcept {
    return {.radiusPage = radius_,
            .previousPositionPage = previousPositionPage_,
            .previousVelocityPage = previousVelocityPage_,
            .previousTimeSeconds = previousTimeSeconds_,
            .initialized = initialized_};
  }

  void restore(Snapshot snapshot) noexcept {
    radius_ = snapshot.radiusPage;
    previousPositionPage_ = snapshot.previousPositionPage;
    previousVelocityPage_ = snapshot.previousVelocityPage;
    previousTimeSeconds_ = snapshot.previousTimeSeconds;
    initialized_ = snapshot.initialized;
  }

 private:
  VelocityWidthPoint apply(const NormalizedInput& input, Vec2 velocity,
                           bool initialize);

  const SignatureStrokeStyle& style_;
  double radius_ = 0.0;
  Vec2 previousPositionPage_;
  Vec2 previousVelocityPage_;
  double previousTimeSeconds_ = 0.0;
  bool initialized_ = false;
};

}  // namespace margelo::nitro::inksignpdf::detail
