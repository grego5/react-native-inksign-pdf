#include "StrokeEngineC.h"

#include <cstdint>

extern "C" int inksign_stroke_engine_archive_smoke() noexcept {
  NSEStrokeEngineRef engine = nse_stroke_engine_create();
  if (engine == nullptr) return 1;

  if (nse_stroke_engine_configure_pen(engine, 1.0, 4.0, 0.25, 1.0) !=
      NSEStrokeStatusOk) {
    nse_stroke_engine_destroy(engine);
    return 2;
  }

  const NSEStrokeInput down{
      .x = 10.0, .y = 10.0, .time = 0.0, .pressure = 0.5,
      .tilt = 0.0, .orientation = 0.0,
  };
  const NSEStrokeInput move{
      .x = 20.0, .y = 20.0, .time = 0.01, .pressure = 0.5,
      .tilt = 0.0, .orientation = 0.0,
  };
  const NSEStrokeInput up{
      .x = 30.0, .y = 30.0, .time = 0.02, .pressure = 0.5,
      .tilt = 0.0, .orientation = 0.0,
  };

  const bool valid = nse_stroke_engine_begin(engine, down) == NSEStrokeStatusOk &&
                     nse_stroke_engine_update(engine, move) == NSEStrokeStatusOk &&
                     nse_stroke_engine_end(engine, up) == NSEStrokeStatusOk &&
                     nse_stroke_engine_frame(engine) != nullptr;
  nse_stroke_engine_destroy(engine);
  return valid ? 0 : 3;
}
