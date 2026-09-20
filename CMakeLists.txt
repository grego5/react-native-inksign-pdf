cmake_minimum_required(VERSION 3.22)

project(ReactNativeInkSignInkEngine LANGUAGES C CXX)

option(INK_ENGINE_SANITIZE "Enable AddressSanitizer and UBSan" OFF)
option(ENABLE_PERFETTO_TRACE
  "Compile Android Perfetto/ATrace instrumentation into source targets" OFF)

if(INK_ENGINE_SANITIZE AND NOT MSVC)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
if(MSVC)
  # Abseil's configure probe and Google Ink's numbers header both use the
  # standard-conforming __cplusplus value on MSVC.
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /std:c++20 /Zc:__cplusplus"
      CACHE STRING "Global C++ flags" FORCE)
endif()

# Google Ink's native geometry is built as an independent static dependency.
# Keep the exact Abseil checkout local so desktop and mobile use the same
# semantics and do not need a package-manager-specific fallback.
set(ABSL_PROPAGATE_CXX_STD ON CACHE BOOL "" FORCE)
set(ABSL_BUILD_TESTING OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/abseil-cpp EXCLUDE_FROM_ALL)
add_subdirectory(third_party/google-ink EXCLUDE_FROM_ALL)

include(${CMAKE_CURRENT_SOURCE_DIR}/cpp/InkEngineSources.cmake)

add_library(UpstreamStrokeGeometry STATIC
  ${INKSIGN_UPSTREAM_GEOMETRY_SOURCES}
)
target_link_libraries(UpstreamStrokeGeometry PUBLIC GoogleInkGeometry)
target_include_directories(UpstreamStrokeGeometry PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/cpp
)
target_compile_features(UpstreamStrokeGeometry PUBLIC cxx_std_20)
target_compile_definitions(UpstreamStrokeGeometry PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)

add_library(UpstreamStrokeOutput STATIC
  ${INKSIGN_UPSTREAM_OUTPUT_SOURCES}
)
target_link_libraries(UpstreamStrokeOutput PUBLIC UpstreamStrokeGeometry)
target_include_directories(UpstreamStrokeOutput PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/cpp)
target_compile_features(UpstreamStrokeOutput PUBLIC cxx_std_20)

add_library(InkEngine STATIC
  ${INKSIGN_INK_ENGINE_SOURCES}
)

target_link_libraries(InkEngine PUBLIC UpstreamStrokeOutput)

target_include_directories(InkEngine PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/cpp
)
target_include_directories(InkEngine PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_definitions(InkEngine PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)

add_library(StrokeReplay STATIC
  cpp/replay/ContinuityDiagnostics.cpp
  cpp/replay/StrokeReplay.cpp
  cpp/replay/StrokeReplayCsv.cpp
  cpp/replay/StrokeReplayValidation.cpp
  cpp/replay/StrokeReplaySvg.cpp
)
target_link_libraries(StrokeReplay PUBLIC InkEngine StartupEnvelopeEvidence)
target_include_directories(StrokeReplay PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/cpp)

if(MSVC)
  target_compile_options(InkEngine PRIVATE /W4 /permissive-)
else()
target_compile_options(InkEngine PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(InkEngineTests
  cpp/tests/engine/InkEngine.test.cpp)
target_link_libraries(InkEngineTests PRIVATE InkEngine)

add_executable(StrokeBatchTests
  cpp/tests/engine/StrokeBatch.test.cpp)
target_link_libraries(StrokeBatchTests PRIVATE InkEngine)

add_executable(StrokeFixtureTests
  cpp/tests/engine/StrokeFixtures.test.cpp
)
target_link_libraries(StrokeFixtureTests PRIVATE InkEngine)

add_executable(StrokePerformanceTests
  cpp/tests/engine/StrokePerformance.test.cpp
)
target_link_libraries(StrokePerformanceTests PRIVATE InkEngine)

add_executable(StrokeCheckpointTests
  cpp/tests/engine/SignatureBrushTipModeler.test.cpp
  cpp/tests/engine/StrokeCheckpoint.test.cpp
)
target_link_libraries(StrokeCheckpointTests PRIVATE InkEngine)

add_executable(InkEngineCTests
  cpp/tests/engine/InkEngineC.test.cpp
)
target_link_libraries(InkEngineCTests PRIVATE InkEngine)

add_executable(ink_engine_cli
  tools/ink_engine_cli.cpp
)
target_link_libraries(ink_engine_cli PRIVATE StrokeReplay)

add_executable(StrokeReplayTests cpp/tests/replay/StrokeReplay.test.cpp)
target_link_libraries(StrokeReplayTests PRIVATE StrokeReplay)
target_compile_definitions(StrokeReplayTests PRIVATE
  NSE_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")

add_executable(InputNormalizerTests cpp/tests/input/InputNormalizer.test.cpp)
target_link_libraries(InputNormalizerTests PRIVATE InkEngine)

add_executable(CurrentInkInputModelerTests
  cpp/tests/input/CurrentInkInputModeler.test.cpp)
target_link_libraries(CurrentInkInputModelerTests PRIVATE InkEngine)

add_executable(CommittedCenterlineTests cpp/tests/modeling/CommittedCenterline.test.cpp)
target_link_libraries(CommittedCenterlineTests PRIVATE StrokeReplay)
target_compile_definitions(CommittedCenterlineTests PRIVATE
  NSE_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")

add_executable(ContactLifecycleTests cpp/tests/modeling/ContactLifecycle.test.cpp)
target_link_libraries(ContactLifecycleTests PRIVATE InkEngine)

add_executable(VelocityWidthModelTests cpp/tests/modeling/VelocityWidthModel.test.cpp)
target_link_libraries(VelocityWidthModelTests PRIVATE StrokeReplay)
target_compile_definitions(VelocityWidthModelTests PRIVATE
  NSE_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
add_executable(UpstreamGeometryTests
  cpp/tests/upstream/UpstreamGeometry.test.cpp)
target_link_libraries(UpstreamGeometryTests PRIVATE UpstreamStrokeGeometry)

add_executable(UpstreamPolicyTests
  cpp/tests/upstream/UpstreamPolicy.test.cpp)
target_link_libraries(UpstreamPolicyTests PRIVATE InkEngine UpstreamStrokeGeometry)

add_executable(UpstreamOutputTests
  cpp/tests/upstream/UpstreamOutput.test.cpp)
target_link_libraries(UpstreamOutputTests PRIVATE UpstreamStrokeOutput)

add_library(StartupEnvelopeEvidence STATIC cpp/circular/StartupEnvelope.cpp)
target_include_directories(StartupEnvelopeEvidence PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/cpp)
add_executable(FrameTransportTests
  cpp/tests/support/FrameTransport.test.cpp
  cpp/tests/support/FrameTransport.cpp)
target_link_libraries(FrameTransportTests PRIVATE StrokeReplay)
target_compile_definitions(FrameTransportTests PRIVATE
  NSE_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")

enable_testing()
add_test(NAME InkEngineTests COMMAND InkEngineTests)
add_test(NAME StrokeBatchTests COMMAND StrokeBatchTests)
add_test(NAME StrokeFixtureTests COMMAND StrokeFixtureTests)
add_test(NAME StrokePerformanceTests COMMAND StrokePerformanceTests)
add_test(NAME StrokeCheckpointTests COMMAND StrokeCheckpointTests)
add_test(NAME InkEngineCTests COMMAND InkEngineCTests)
add_test(NAME StrokeReplayTests COMMAND StrokeReplayTests)
add_test(NAME InputNormalizerTests COMMAND InputNormalizerTests)
add_test(NAME CurrentInkInputModelerTests COMMAND CurrentInkInputModelerTests)
add_test(NAME CommittedCenterlineTests COMMAND CommittedCenterlineTests)
add_test(NAME ContactLifecycleTests COMMAND ContactLifecycleTests)
add_test(NAME VelocityWidthModelTests COMMAND VelocityWidthModelTests)
add_test(NAME UpstreamGeometryTests COMMAND UpstreamGeometryTests)
add_test(NAME UpstreamPolicyTests COMMAND UpstreamPolicyTests)
add_test(NAME UpstreamOutputTests COMMAND UpstreamOutputTests)
add_test(NAME FrameTransportTests COMMAND FrameTransportTests)
