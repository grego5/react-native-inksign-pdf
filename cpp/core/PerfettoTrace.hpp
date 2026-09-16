#pragma once

#include <cstdint>
#include <limits>

#if defined(__ANDROID__)
#include <android/trace.h>
#endif

namespace margelo::nitro::inksignpdf::detail {

// Android-only tracing with a compile-time no-op on host platforms. The
// enabled check keeps disabled tracing to one inexpensive branch per scope or
// counter and does not alter the stroke data path.
class ScopedPerfettoTrace final {
 public:
  explicit ScopedPerfettoTrace(const char* name) noexcept {
#if defined(__ANDROID__)
    enabled_ = ATrace_isEnabled();
    if (enabled_) ATrace_beginSection(name);
#else
    (void)name;
#endif
  }

  ~ScopedPerfettoTrace() {
#if defined(__ANDROID__)
    if (enabled_) ATrace_endSection();
#endif
  }

 private:
#if defined(__ANDROID__)
  bool enabled_ = false;
#endif
};

inline void perfettoCounter(const char* name, std::uint64_t value) noexcept {
#if defined(__ANDROID__)
  if (!ATrace_isEnabled()) return;
  constexpr auto maxValue = static_cast<std::uint64_t>(
      std::numeric_limits<std::int64_t>::max());
  ATrace_setCounter(
      name, static_cast<std::int64_t>(value > maxValue ? maxValue : value));
#else
  (void)name;
  (void)value;
#endif
}

}  // namespace margelo::nitro::inksignpdf::detail
