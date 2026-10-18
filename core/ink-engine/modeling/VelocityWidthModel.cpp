#include "modeling/VelocityWidthModel.hpp"
#include "primitives/StrokePrimitives.hpp"

#include <algorithm>
#include <cmath>

namespace margelo::nitro::inksignpdf::detail {

VelocityWidthModel::VelocityWidthModel(const SignatureStrokeStyle& style)
    : style_(style) {}

VelocityWidthPoint VelocityWidthModel::begin(const NormalizedInput& input,
                                             Vec2 velocity) {
  return apply(input, velocity, true);
}

VelocityWidthPoint VelocityWidthModel::dot(const NormalizedInput& input,
                                            double radius) const {
  const double clampedRadius = std::clamp(
      std::isfinite(radius) ? radius : style_.minimumRadius(),
      style_.minimumRadius(), style_.maximumRadius());
  return {.input = input,
          .dtSeconds = 0.0,
          .turnFactor = 1.0,
          .effectiveSpeedDisplay = 0.0,
          .targetRadius = clampedRadius,
          .segmentDistance = 0.0,
          .responseDistancePage = style_.responseDistancePage(),
          .responseAlpha = 0.0,
          .radius = clampedRadius};
}

VelocityWidthPoint VelocityWidthModel::update(const NormalizedInput& input,
                                              Vec2 velocity) {
  return apply(input, velocity, false);
}

void VelocityWidthModel::cancel() {
  radius_ = style_.minimumRadius();
  previousPositionPage_ = {};
  previousVelocityPage_ = {};
  previousTimeSeconds_ = 0.0;
  initialized_ = false;
}

VelocityWidthPoint VelocityWidthModel::apply(const NormalizedInput& input,
                                             Vec2 velocity,
                                             bool initialize) {
  const double speed = isFinite(velocity) ? length(velocity) : 0.0;
  const double effectiveSpeedDisplay =
      speed * style_.logicalDisplayUnitsPerPageUnit();
  const double unattenuatedTarget =
      style_.radiusTargetForEffectiveSpeedDisplay(effectiveSpeedDisplay);
  if (initialize || !initialized_) {
    radius_ = style_.minimumRadius();
    previousPositionPage_ = input.position;
    previousVelocityPage_ = velocity;
    previousTimeSeconds_ = input.time;
    initialized_ = true;
    return {.input = input,
            .dtSeconds = 0.0,
            .turnFactor = 1.0,
            .effectiveSpeedDisplay = effectiveSpeedDisplay,
            .targetRadius = unattenuatedTarget,
            .segmentDistance = 0.0,
            .responseDistancePage = style_.responseDistancePage(),
            .responseAlpha = 0.0,
            .radius = radius_};
  }

  const double dtSeconds = input.time - previousTimeSeconds_;
  const double previousSpeed = length(previousVelocityPage_);
  double turnFactor = 1.0;
  if (dtSeconds > 0.0 && previousSpeed > 0.0 && speed > 0.0) {
    const double cosine = std::clamp(
        ::margelo::nitro::inksignpdf::detail::dot(
            scale(previousVelocityPage_, 1.0 / previousSpeed),
            scale(velocity, 1.0 / speed)),
        -1.0, 1.0);
    const double angle = std::acos(cosine);
    turnFactor = std::pow(std::clamp(
                              (std::cos((angle / dtSeconds) / 90.0) - 0.65) /
                                  0.35,
                              0.0, 1.0),
                          3.0);
  }
  const double effectiveSpeed = speed *
      style_.logicalDisplayUnitsPerPageUnit() * turnFactor;
  const double targetRadius =
      style_.radiusTargetForEffectiveSpeedDisplay(effectiveSpeed);
  const double segmentDistance = distance(input.position, previousPositionPage_);
  const bool contracting = targetRadius < radius_;
  const double responseDistancePage = style_.responseDistancePage(contracting);
  const double alpha =
      style_.distanceResponseFactor(segmentDistance, contracting);
  radius_ += alpha * (targetRadius - radius_);
  radius_ = std::clamp(radius_, style_.minimumRadius(),
                       style_.maximumRadius());
  previousPositionPage_ = input.position;
  previousVelocityPage_ = velocity;
  previousTimeSeconds_ = input.time;
  return {.input = input,
          .dtSeconds = dtSeconds,
          .turnFactor = turnFactor,
          .effectiveSpeedDisplay = effectiveSpeed,
          .targetRadius = targetRadius,
          .segmentDistance = segmentDistance,
          .responseDistancePage = responseDistancePage,
          .responseAlpha = alpha,
          .radius = radius_};
}

}  // namespace margelo::nitro::inksignpdf::detail
