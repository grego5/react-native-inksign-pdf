#include "modeling/ContactLifecycle.hpp"

#include <algorithm>

namespace margelo::nitro::inksignpdf::detail {
namespace {
constexpr double kMinimumDwell = 0.040;
constexpr double kMaximumDwell = 0.350;
constexpr double kMinimumRadiusFactor = 0.38;
}

double durationSensitiveInitialRadius(double dwellDuration,
                                      double maximumRadius) {
  const double safeMaximum = std::max(0.0, maximumRadius);
  const double minimumRadius = kMinimumRadiusFactor * safeMaximum;
  const double normalized =
      std::clamp((dwellDuration - kMinimumDwell) /
                     (kMaximumDwell - kMinimumDwell),
                 0.0, 1.0);
  const double pressFactor = normalized * normalized * (3.0 - 2.0 * normalized);
  return std::clamp(minimumRadius +
                        (safeMaximum - minimumRadius) * pressFactor,
                    minimumRadius, safeMaximum);
}

void ContactLifecycle::begin(double downTime) {
  downTime_ = downTime;
  active_ = true;
  movementAccepted_ = false;
}

double ContactLifecycle::acceptMovement(double movementTime) {
  movementAccepted_ = true;
  return std::max(0.0, movementTime - downTime_);
}

double ContactLifecycle::end(double upTime) const {
  return std::max(0.0, upTime - downTime_);
}

void ContactLifecycle::reset() {
  downTime_ = 0.0;
  active_ = false;
  movementAccepted_ = false;
}

}  // namespace margelo::nitro::inksignpdf::detail
