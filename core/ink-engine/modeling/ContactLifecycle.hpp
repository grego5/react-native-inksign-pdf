#pragma once

namespace margelo::nitro::inksignpdf::detail {

// Production contact-size calibration. Durations are monotonic seconds.
double durationSensitiveInitialRadius(double dwellDuration,
                                      double maximumRadius);

class ContactLifecycle {
 public:
  void begin(double downTime);
  double acceptMovement(double movementTime);
  double end(double upTime) const;
  void reset();

  bool active() const { return active_; }
  bool movementAccepted() const { return movementAccepted_; }

 private:
  double downTime_ = 0.0;
  bool active_ = false;
  bool movementAccepted_ = false;
};

}  // namespace margelo::nitro::inksignpdf::detail
