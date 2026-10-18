#include "ink-engine/tests/support/TestSupport.hpp"
#include "input/InputNormalizer.hpp"
#include "primitives/StrokePrimitives.hpp"

#include <cmath>
#include <limits>

using namespace margelo::nitro::inksignpdf;
using namespace margelo::nitro::inksignpdf::detail;

namespace {

InkStrokeInput sample(InkStrokeEventType event,
                   double time,
                   double x,
                   double y,
                   double pressure = -1.0,
                   double tilt = -1.0,
                   double orientation = -1.0) {
  return {.eventType = event,
          .position = {x, y},
          .time = time,
          .pressure = pressure,
          .tilt = tilt,
          .orientation = orientation};
}

}  // namespace

int main() {
  CHECK(length({3.0, 4.0}) == 5.0);
  CHECK(distance({1.0, 1.0}, {4.0, 5.0}) == 5.0);
  CHECK(dot({2.0, 3.0}, {4.0, -1.0}) == 5.0);
  const Vec2 unit = normalize({0.0, 5.0});
  CHECK(unit.x == 0.0 && unit.y == 1.0);
  const Vec2 fallback = normalize({0.0, 0.0}, {0.0, -1.0});
  CHECK(fallback.x == 0.0 && fallback.y == -1.0);
  const Vec2 midpoint = lerp({2.0, 4.0}, {6.0, 8.0}, 0.5);
  CHECK(midpoint.x == 4.0 && midpoint.y == 6.0);

  NormalizedInput output;
  InputNormalizer lifecycle;
  CHECK(lifecycle.update(sample(InkStrokeEventType::Move, 0.0, 0.0, 0.0),
                         output).code == InputStatusCode::NotInProgress);
  CHECK(lifecycle.begin(sample(InkStrokeEventType::Move, 0.0, 0.0, 0.0),
                        output).code == InputStatusCode::InvalidEvent);
  CHECK(!lifecycle.inProgress());
  CHECK(lifecycle.begin(sample(InkStrokeEventType::Down, 0.0, 0.0, 0.0),
                        output).ok());
  CHECK(lifecycle.begin(sample(InkStrokeEventType::Down, 0.1, 1.0, 0.0),
                        output).code == InputStatusCode::AlreadyInProgress);
  CHECK(lifecycle.end(sample(InkStrokeEventType::Move, 0.1, 1.0, 0.0),
                      output).code == InputStatusCode::InvalidEvent);
  CHECK(lifecycle.inProgress());
  CHECK(lifecycle.end(sample(InkStrokeEventType::Up, 0.1, 1.0, 0.0), output).ok());
  CHECK(!lifecycle.inProgress());

  InputNormalizer validation;
  CHECK(validation.begin(sample(InkStrokeEventType::Down, 10.0, 1.0, 2.0),
                         output).ok());
  CHECK(!output.stylus.pressure && !output.stylus.tilt &&
        !output.stylus.orientation);
  const InkStrokeInput duplicate =
      sample(InkStrokeEventType::Move, 10.1, 2.0, 3.0, 0.5, 0.7, 1.2);
  CHECK(validation.update(duplicate, output).ok());
  CHECK(output.stylus.pressure == 0.5);
  CHECK(output.stylus.tilt == 0.7);
  CHECK(output.stylus.orientation == 1.2);
  CHECK(validation.update(duplicate, output).code ==
        InputStatusCode::DuplicateInput);
  CHECK(validation.update(sample(InkStrokeEventType::Move, 10.05, 3.0, 3.0),
                          output).code == InputStatusCode::TimeWentBackwards);
  // Equal timestamps remain exact and are accepted when the sample differs.
  CHECK(validation.update(sample(InkStrokeEventType::Move, 10.1, 3.0, 3.0),
                          output).ok());
  CHECK(output.time == 10.1 && output.position.x == 3.0);
  // A gap has constant work here: it emits exactly the supplied endpoint.
  CHECK(validation.update(sample(InkStrokeEventType::Move, 1000000.0, 4.0, 3.0),
                          output).ok());
  CHECK(output.time == 1000000.0 && output.position.x == 4.0);

  const double infinity = std::numeric_limits<double>::infinity();
  CHECK(validation.update(sample(InkStrokeEventType::Move, 1000001.0, infinity,
                                 0.0), output).code ==
        InputStatusCode::InvalidValue);
  CHECK(validation.update(sample(InkStrokeEventType::Move, 1000001.0, 5.0, 0.0,
                                 -0.5), output).code ==
        InputStatusCode::InvalidValue);
  CHECK(validation.update(sample(InkStrokeEventType::Move, 1000001.0, 5.0, 0.0,
                                 std::numeric_limits<double>::quiet_NaN()),
                          output).code == InputStatusCode::InvalidValue);

  InputNormalizer reset;
  CHECK(reset.begin(sample(InkStrokeEventType::Down, 0.0, 0.0, 0.0), output).ok());
  reset.cancel();
  CHECK(!reset.inProgress());
  CHECK(reset.update(sample(InkStrokeEventType::Move, 21.0, 21.0, 0.0),
                     output).code == InputStatusCode::NotInProgress);
  CHECK(reset.begin(sample(InkStrokeEventType::Down, 30.0, 0.0, 0.0), output).ok());

  return 0;
}
