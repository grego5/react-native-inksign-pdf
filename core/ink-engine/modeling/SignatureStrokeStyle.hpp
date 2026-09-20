#pragma once

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace margelo::nitro::inksignpdf::detail {

// Stroke-scoped signature policy. It owns width and terminal style policy;
// VelocityWidthModel owns the radius recurrence state.
class SignatureStrokeStyle {
 public:
  // Modeled velocity is in frozen page units per second. Convert it through
  // the stroke's display scale before comparing it with this fixed reference.
  static constexpr double kVelocityReferenceRate = 960.0;
  // Styling calibration, not a geometric invariant or public knob.
  static constexpr double kGrowthDistanceResponseStrength = 6.0;
  static constexpr double kContractionDistanceResponseStrength = 2.0;
  static constexpr double kMinimumTerminalRadiusFraction = 0.25;
  static constexpr double kMaximumTaperDistanceLogical = 48.0;
  struct Taper {
    double distance = 0.0;
    // Continuous terminal attenuation amount in [0, 1].
    double strength = 0.0;

    bool active() const noexcept {
      return distance > 0.0 && strength > 0.0;
    }
  };

  struct Snapshot {
    double lastMovingRealSpeed = 0.0;
    Taper taper;
    double maximumTaperDistance = kMaximumTaperDistanceLogical;
    double minimumTerminalRadius = 0.0;
    double logicalDisplayUnitsPerPageUnit = 1.0;
  };

  SignatureStrokeStyle(double minimumRadius, double maximumRadius,
                       double logicalDisplayUnitsPerPageUnit = 1.0)
      : minimumRadius_(minimumRadius), maximumRadius_(maximumRadius),
        logicalDisplayUnitsPerPageUnit_(logicalDisplayUnitsPerPageUnit) {
    if (!std::isfinite(minimumRadius_) || !std::isfinite(maximumRadius_) ||
        minimumRadius_ < 0.0 || maximumRadius_ < minimumRadius_) {
      throw std::invalid_argument("invalid width bounds");
    }
    if (!std::isfinite(logicalDisplayUnitsPerPageUnit_) ||
        logicalDisplayUnitsPerPageUnit_ <= 0.0) {
      throw std::invalid_argument("invalid display scale");
    }
    refreshTerminalStyle();
  }

  double minimumRadius() const noexcept { return minimumRadius_; }
  double maximumRadius() const noexcept { return maximumRadius_; }

  void reset() noexcept {
    lastMovingRealSpeed_ = 0.0;
    refreshTerminalStyle();
  }

  // Zero/stationary and invalid samples do not replace the last moving real
  // speed. Prediction uses snapshotForSpeed(), never this mutating method.
  void observeRealSpeed(double speed) noexcept {
    if (std::isfinite(speed) && speed > 0.0) {
      lastMovingRealSpeed_ = speed;
      refreshTerminalStyle();
    }
  }

  double lastMovingRealSpeed() const noexcept { return lastMovingRealSpeed_; }
  const Taper& taper() const noexcept { return taper_; }
  Snapshot snapshot() const noexcept {
    return {.lastMovingRealSpeed = lastMovingRealSpeed_,
            .taper = taper_,
            .maximumTaperDistance = maximumTaperDistance(),
            .minimumTerminalRadius = minimumTerminalRadius(),
            .logicalDisplayUnitsPerPageUnit = logicalDisplayUnitsPerPageUnit_};
  }

  SignatureStrokeStyle snapshotForSpeed(double speed) const noexcept {
    SignatureStrokeStyle result = *this;
    result.observeRealSpeed(speed);
    return result;
  }

  double logicalDisplayUnitsPerPageUnit() const noexcept {
    return logicalDisplayUnitsPerPageUnit_;
  }

  double brushSizePage() const noexcept { return 2.0 * maximumRadius_; }

  double distanceResponseStrength(bool contracting = false) const noexcept {
    return contracting ? kContractionDistanceResponseStrength
                       : kGrowthDistanceResponseStrength;
  }

  double responseDistancePage(bool contracting = false) const noexcept {
    return brushSizePage() * distanceResponseStrength(contracting);
  }

  double normalizedSpeed(double speed) const noexcept {
    return normalizedSpeedForDisplaySpeed(speed);
  }

  double radiusTargetForEffectiveSpeedDisplay(
      double effectiveSpeedDisplay) const noexcept {
    const double speed = std::isfinite(effectiveSpeedDisplay) &&
            effectiveSpeedDisplay > 0.0
        ? effectiveSpeedDisplay
        : 0.0;
    const double x = speed / kVelocityReferenceRate;
    const double u = std::exp(-4.0 * std::exp(-4.0 * x));
    return minimumRadius_ + u * (maximumRadius_ - minimumRadius_);
  }

  double distanceResponseFactor(double distancePage,
                                bool contracting = false) const noexcept {
    if (minimumRadius_ == maximumRadius_ ||
        !std::isfinite(distancePage) || distancePage <= 0.0)
      return 0.0;
    const double response = responseDistancePage(contracting);
    if (!(response > 0.0) || !std::isfinite(response)) return 0.0;
    return -std::expm1(-distancePage / response);
  }

  double terminalResponseAmount(double speed) const noexcept {
    const double displaySpeed =
        std::isfinite(speed) && speed > 0.0
        ? speed * logicalDisplayUnitsPerPageUnit_
        : 0.0;
    if (!(displaySpeed > 0.0) || !std::isfinite(displaySpeed))
      return displaySpeed > 0.0 ? 1.0 : 0.0;
    return -std::expm1(-displaySpeed / kVelocityReferenceRate);
  }

  static double terminalRadiusAt(
      double ordinaryRadius, double remaining, double effectiveDistance,
      double amount, double minimumRadius) noexcept {
    if (effectiveDistance <= 0.0 || amount <= 0.0 ||
        remaining >= effectiveDistance)
      return ordinaryRadius;
    const double u = std::clamp(
        std::max(remaining, 0.0) / effectiveDistance, 0.0, 1.0);
    const double smooth = u * u * (3.0 - 2.0 * u);
    const double cubicInfluence = 1.0 - smooth;
    const double linearInfluence = 1.0 - u;
    // Higher speed makes the shrink more gradual across the tail by blending
    // the cubic profile toward an even linear profile.
    const double speedAmount = std::clamp(amount, 0.0, 1.0);
    const double influence = cubicInfluence +
        speedAmount * (linearInfluence - cubicInfluence);
    const double attenuated = ordinaryRadius *
        (1.0 - speedAmount * influence);
    return std::max(std::min(minimumRadius, ordinaryRadius), attenuated);
  }

 private:
  double normalizedSpeedForDisplaySpeed(double speed) const noexcept {
    const double movingSpeed = std::isfinite(speed) && speed > 0.0 ? speed : 0.0;
    const double displaySpeed =
        movingSpeed * logicalDisplayUnitsPerPageUnit_;
    return std::clamp(displaySpeed / kVelocityReferenceRate, 0.0, 1.0);
  }

  double maximumTaperDistance() const noexcept {
    return kMaximumTaperDistanceLogical /
        logicalDisplayUnitsPerPageUnit_;
  }

  double minimumTerminalRadius() const noexcept {
    return minimumRadius_ * kMinimumTerminalRadiusFraction;
  }

  void refreshTerminalStyle() noexcept {
    const double amount = terminalResponseAmount(lastMovingRealSpeed_);
    taper_ = {.distance = maximumTaperDistance() * amount,
               .strength = amount};
  }

 private:
  double minimumRadius_ = 0.0;
  double maximumRadius_ = 0.0;
  double logicalDisplayUnitsPerPageUnit_ = 1.0;
  double lastMovingRealSpeed_ = 0.0;
  Taper taper_;
};

}  // namespace margelo::nitro::inksignpdf::detail
