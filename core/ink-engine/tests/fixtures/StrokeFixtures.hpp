#pragma once

#include "InkEngine.hpp"

#include <string_view>
#include <vector>

namespace margelo::nitro::inksignpdf::fixtures {

struct Fixture {
  std::string_view name;
  std::vector<InkStrokeInput> inputs;
};

inline InkStrokeInput sample(InkStrokeEventType event, double time, double x,
                          double y, double pressure = -1.0) {
  return {.eventType = event,
          .position = {x, y},
          .time = time,
          .pressure = pressure};
}

inline std::vector<Fixture> all() {
  using Event = InkStrokeEventType;
  return {
      {"signature",
       {sample(Event::Down, 0.000, 8, 40, 0.35),
        sample(Event::Move, 0.009, 14, 22, 0.42),
        sample(Event::Move, 0.018, 20, 48, 0.50),
        sample(Event::Move, 0.027, 27, 29, 0.58),
        sample(Event::Move, 0.036, 35, 44, 0.62),
        sample(Event::Move, 0.045, 44, 35, 0.56),
        sample(Event::Move, 0.054, 55, 41, 0.48),
        sample(Event::Move, 0.063, 68, 38, 0.40),
        sample(Event::Move, 0.072, 84, 42, 0.32),
        sample(Event::Up, 0.081, 102, 40, 0.25)}},
      {"tight-loop",
       {sample(Event::Down, 0.000, 40, 20),
        sample(Event::Move, 0.008, 48, 23),
        sample(Event::Move, 0.016, 52, 30),
        sample(Event::Move, 0.024, 50, 39),
        sample(Event::Move, 0.032, 42, 44),
        sample(Event::Move, 0.040, 33, 42),
        sample(Event::Move, 0.048, 27, 35),
        sample(Event::Move, 0.056, 28, 26),
        sample(Event::Move, 0.064, 35, 20),
        sample(Event::Move, 0.072, 44, 20),
        sample(Event::Move, 0.080, 50, 27),
        sample(Event::Up, 0.088, 49, 35)}},
      {"reversal",
       {sample(Event::Down, 0.000, 5, 10),
        sample(Event::Move, 0.010, 30, 10),
        sample(Event::Move, 0.020, 55, 10),
        sample(Event::Move, 0.030, 34, 11),
        sample(Event::Move, 0.040, 12, 12),
        sample(Event::Move, 0.050, 38, 14),
        sample(Event::Up, 0.060, 64, 16)}},
      {"sharp-corners",
       {sample(Event::Down, 0.000, 10, 10),
        sample(Event::Move, 0.012, 50, 10),
        sample(Event::Move, 0.024, 50, 45),
        sample(Event::Move, 0.036, 20, 45),
        sample(Event::Move, 0.048, 20, 25),
        sample(Event::Up, 0.060, 70, 25)}},
      {"low-speed-jitter",
       {sample(Event::Down, 0.000, 10.0, 30.0),
        sample(Event::Move, 0.010, 10.8, 30.4),
        sample(Event::Move, 0.020, 11.7, 29.7),
        sample(Event::Move, 0.030, 12.5, 30.5),
        sample(Event::Move, 0.040, 13.4, 29.8),
        sample(Event::Move, 0.050, 14.2, 30.3),
        sample(Event::Move, 0.060, 15.1, 29.9),
        sample(Event::Up, 0.070, 16.0, 30.0)}},
      {"pressure-stable",
       {sample(Event::Down, 0.000, 4, 8, 0.2),
        sample(Event::Move, 0.010, 12, 10, 0.45),
         sample(Event::Move, 0.020, 22, 13, 0.55),
         sample(Event::Move, 0.030, 36, 17, 0.65),
        sample(Event::Move, 0.040, 52, 19, 0.8),
        sample(Event::Up, 0.050, 67, 20, 0.6)}}};
}

}  // namespace margelo::nitro::inksignpdf::fixtures
