#pragma once

#include <iostream>
#include <cstdlib>

inline void checkTestCondition(bool condition, const char* expression,
                               const char* file, int line) {
  if (!condition) {
    std::cerr << "CHECK failed: " << expression << " at " << file << ':'
              << line << '\n';
    // Exit normally with failure instead of raising SIGABRT. On Windows,
    // abort can invoke the debugger/critical-error dialog and block CTest.
    std::exit(EXIT_FAILURE);
  }
}

// Unlike assert(), CHECK always evaluates its expression in Release builds.
// The native tests deliberately put lifecycle calls inside these checks so a
// release benchmark cannot silently benchmark an empty loop under NDEBUG.
#define CHECK(condition)                                                     \
  do {                                                                       \
    checkTestCondition(static_cast<bool>(condition), #condition, __FILE__,   \
                       __LINE__);                                            \
  } while (false)
