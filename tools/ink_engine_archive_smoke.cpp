#include "InkEngineC.h"

#include <cstdint>

extern "C" int inksign_ink_engine_archive_smoke() noexcept {
  InkEngineRef engine = ink_engine_create();
  if (engine == nullptr) return 1;

  if (ink_engine_configure_pen(engine, 1.0, 4.0, 0.25, 1.0) !=
      InkEngineStatusOk) {
    ink_engine_destroy(engine);
    return 2;
  }

  const InkEngineInput down{
      .x = 10.0, .y = 10.0, .time = 0.0, .pressure = 0.5,
      .tilt = 0.0, .orientation = 0.0,
  };
  const InkEngineInput move{
      .x = 20.0, .y = 20.0, .time = 0.01, .pressure = 0.5,
      .tilt = 0.0, .orientation = 0.0,
  };
  const InkEngineInput up{
      .x = 30.0, .y = 30.0, .time = 0.02, .pressure = 0.5,
      .tilt = 0.0, .orientation = 0.0,
  };

  const bool valid = ink_engine_begin(engine, down) == InkEngineStatusOk &&
                     ink_engine_update(engine, move) == InkEngineStatusOk &&
                     ink_engine_end(engine, up) == InkEngineStatusOk &&
                     ink_engine_frame(engine) != nullptr;
  ink_engine_destroy(engine);
  return valid ? 0 : 3;
}
