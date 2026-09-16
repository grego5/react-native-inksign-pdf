#include "tests/support/TestSupport.hpp"
#include "modeling/ContactLifecycle.hpp"

using namespace margelo::nitro::inksignpdf::detail;

int main() {
  constexpr double maximumRadius = 10.0;
  CHECK(durationSensitiveInitialRadius(0.0, maximumRadius) == 3.8);
  CHECK(durationSensitiveInitialRadius(0.040, maximumRadius) == 3.8);
  CHECK(durationSensitiveInitialRadius(0.350, maximumRadius) == maximumRadius);
  CHECK(durationSensitiveInitialRadius(1.0, maximumRadius) == maximumRadius);
  CHECK(durationSensitiveInitialRadius(0.195, maximumRadius) == 6.9);
  double previous = 0.0;
  for (int milliseconds = 0; milliseconds <= 500; ++milliseconds) {
    const double radius = durationSensitiveInitialRadius(
        milliseconds / 1000.0, maximumRadius);
    CHECK(radius >= 3.8);
    CHECK(radius <= maximumRadius);
    CHECK(radius >= previous);
    previous = radius;
  }

  ContactLifecycle lifecycle;
  CHECK(!lifecycle.active());

  lifecycle.begin(2.0);
  CHECK(lifecycle.active());
  CHECK(!lifecycle.movementAccepted());
  CHECK(lifecycle.end(2.025) > 0.0249);
  CHECK(lifecycle.end(2.025) < 0.0251);

  CHECK(lifecycle.acceptMovement(2.2) > 0.1999);
  CHECK(lifecycle.acceptMovement(2.2) < 0.2001);
  CHECK(lifecycle.movementAccepted());

  lifecycle.reset();
  CHECK(!lifecycle.active());
  CHECK(!lifecycle.movementAccepted());

  lifecycle.begin(5.0);
  CHECK(lifecycle.end(4.0) == 0.0);
  return 0;
}
