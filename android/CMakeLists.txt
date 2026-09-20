cmake_minimum_required(VERSION 3.22.1)
project(ReactNativeInkSignPdf)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
option(ENABLE_PERFETTO_TRACE
  "Compile Android Perfetto/ATrace instrumentation into source targets" OFF)
option(STROKE_ENGINE_USE_SOURCE
  "Build the stroke engine from repository sources instead of the bundled archive" OFF)
set(STROKE_ENGINE_ARCHIVE_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/stroke-engine" CACHE PATH
  "Directory containing per-ABI bundled stroke-engine archives")
set(STROKE_ENGINE_EXPECTED_NDK_VERSION "" CACHE STRING
  "Expected NDK version recorded in the bundled stroke-engine metadata")
if(MSVC)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /std:c++20 /Zc:__cplusplus")
else()
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++20")
endif()

set(PDFIUM_ROOT "${CMAKE_CURRENT_LIST_DIR}/../third_party/pdfium")
set(PDFIUM_LIBRARY "${CMAKE_CURRENT_LIST_DIR}/build/pdfium/${ANDROID_ABI}/libpdfium.a")
if(NOT EXISTS "${PDFIUM_LIBRARY}")
  message(FATAL_ERROR
    "PDFium is not packaged for Android ABI ${ANDROID_ABI}: ${PDFIUM_LIBRARY}")
endif()

add_library(PDFium STATIC IMPORTED GLOBAL)
set_target_properties(PDFium PROPERTIES
  IMPORTED_LOCATION "${PDFIUM_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${PDFIUM_ROOT}/include"
)

include(${CMAKE_CURRENT_LIST_DIR}/../cpp/StrokeEngineSources.cmake)

if(STROKE_ENGINE_USE_SOURCE)
  # Source mode is explicit for repository development and tests. It is kept
  # complete and independent of the packaged archive.
  set(ABSL_PROPAGATE_CXX_STD ON CACHE BOOL "" FORCE)
  set(ABSL_BUILD_TESTING OFF CACHE BOOL "" FORCE)
  add_subdirectory(../third_party/abseil-cpp
    ${CMAKE_CURRENT_BINARY_DIR}/abseil-cpp EXCLUDE_FROM_ALL)
  add_subdirectory(../third_party/google-ink
    ${CMAKE_CURRENT_BINARY_DIR}/google-ink EXCLUDE_FROM_ALL)

  add_library(UpstreamStrokeGeometry STATIC
    ${INKSIGN_UPSTREAM_GEOMETRY_SOURCES}
  )
  target_link_libraries(UpstreamStrokeGeometry PUBLIC GoogleInkGeometry)
  target_include_directories(UpstreamStrokeGeometry PUBLIC ../cpp)
  target_compile_features(UpstreamStrokeGeometry PUBLIC cxx_std_20)
  target_compile_definitions(UpstreamStrokeGeometry PRIVATE
    ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)
else()
  set(_stroke_engine_supported_abis arm64-v8a x86_64)
  if(NOT ANDROID_ABI IN_LIST _stroke_engine_supported_abis)
    message(FATAL_ERROR
      "No bundled stroke-engine archive is supported for Android ABI ${ANDROID_ABI}. "
      "Supported ABIs: ${_stroke_engine_supported_abis}")
  endif()

  set(STROKE_ENGINE_ARCHIVE
    "${STROKE_ENGINE_ARCHIVE_ROOT}/${ANDROID_ABI}/libinksign_stroke_engine_${ANDROID_ABI}.a")
  set(STROKE_ENGINE_METADATA "${STROKE_ENGINE_ARCHIVE}.json")
  if(NOT EXISTS "${STROKE_ENGINE_ARCHIVE}")
    message(FATAL_ERROR
      "Bundled stroke-engine archive is missing for ${ANDROID_ABI}: "
      "${STROKE_ENGINE_ARCHIVE}. Set -DSTROKE_ENGINE_USE_SOURCE=ON for a "
      "deliberate repository source build.")
  endif()
  if(NOT EXISTS "${STROKE_ENGINE_METADATA}")
    message(FATAL_ERROR
      "Bundled stroke-engine metadata is missing for ${ANDROID_ABI}: "
      "${STROKE_ENGINE_METADATA}")
  endif()

  file(READ "${STROKE_ENGINE_METADATA}" _stroke_engine_metadata)
  string(JSON _stroke_engine_metadata_abi GET "${_stroke_engine_metadata}" abi)
  string(JSON _stroke_engine_metadata_archive GET "${_stroke_engine_metadata}" archive)
  string(JSON _stroke_engine_metadata_api GET "${_stroke_engine_metadata}" apiVersion)
  string(JSON _stroke_engine_metadata_ndk GET "${_stroke_engine_metadata}" ndkVersion)
  string(JSON _stroke_engine_metadata_trace GET "${_stroke_engine_metadata}" perfettoTrace)
  string(JSON _stroke_engine_metadata_size GET "${_stroke_engine_metadata}" sizeBytes)
  string(JSON _stroke_engine_metadata_sha256 GET "${_stroke_engine_metadata}" sha256)
  get_filename_component(_stroke_engine_archive_name "${STROKE_ENGINE_ARCHIVE}" NAME)

  file(READ "${CMAKE_CURRENT_LIST_DIR}/../cpp/StrokeEngineC.h" _stroke_engine_header)
  string(REGEX MATCH
    "NSE_STROKE_ENGINE_API_VERSION[ \t]+([0-9]+)u?"
    _stroke_engine_api_match "${_stroke_engine_header}")
  if(NOT CMAKE_MATCH_1)
    message(FATAL_ERROR "Unable to determine the StrokeEngine C ABI version")
  endif()
  set(_stroke_engine_expected_api "${CMAKE_MATCH_1}")

  if(NOT _stroke_engine_metadata_abi STREQUAL ANDROID_ABI)
    message(FATAL_ERROR
      "Stroke-engine metadata ABI ${_stroke_engine_metadata_abi} does not match "
      "Android ABI ${ANDROID_ABI}")
  endif()
  if(NOT _stroke_engine_metadata_archive STREQUAL _stroke_engine_archive_name)
    message(FATAL_ERROR
      "Stroke-engine metadata archive ${_stroke_engine_metadata_archive} does not "
      "match ${_stroke_engine_archive_name}")
  endif()
  if(NOT _stroke_engine_metadata_api STREQUAL _stroke_engine_expected_api)
    message(FATAL_ERROR
      "Stroke-engine API mismatch: archive has ${_stroke_engine_metadata_api}, "
      "consumer requires ${_stroke_engine_expected_api}")
  endif()
  if(STROKE_ENGINE_EXPECTED_NDK_VERSION AND
     NOT _stroke_engine_metadata_ndk STREQUAL STROKE_ENGINE_EXPECTED_NDK_VERSION)
    message(FATAL_ERROR
      "Stroke-engine archive was built with NDK ${_stroke_engine_metadata_ndk}; "
      "consumer requires ${STROKE_ENGINE_EXPECTED_NDK_VERSION}")
  endif()
  if(_stroke_engine_metadata_trace)
    message(FATAL_ERROR
      "The normal Android consumer cannot link a tracing-enabled stroke archive")
  endif()

  file(SIZE "${STROKE_ENGINE_ARCHIVE}" _stroke_engine_actual_size)
  if(NOT _stroke_engine_actual_size EQUAL _stroke_engine_metadata_size)
    message(FATAL_ERROR
      "Stroke-engine archive size mismatch: metadata says "
      "${_stroke_engine_metadata_size}, file is ${_stroke_engine_actual_size}")
  endif()
  file(SHA256 "${STROKE_ENGINE_ARCHIVE}" _stroke_engine_actual_sha256)
  if(NOT _stroke_engine_actual_sha256 STREQUAL _stroke_engine_metadata_sha256)
    message(FATAL_ERROR
      "Stroke-engine archive SHA-256 mismatch for ${STROKE_ENGINE_ARCHIVE}")
  endif()

  add_library(StrokeEngineBundle STATIC IMPORTED GLOBAL)
  set_target_properties(StrokeEngineBundle PROPERTIES
    IMPORTED_LOCATION "${STROKE_ENGINE_ARCHIVE}")
endif()

add_library(ReactNativeInkSignPdf SHARED
  src/main/cpp/cpp-adapter.cpp
  src/main/cpp/pdfium_render_jni.cpp
  src/main/cpp/pdfium_smoke.cpp
  src/main/cpp/pdfium_session_smoke.cpp
  src/main/cpp/StrokeEngine.cpp
        ../cpp/pdfium/PdfiumDocumentSession.cpp
  ../cpp/pdfium/PdfiumFontCoverage.cpp
  ../cpp/pdfium/PdfiumFontFallback.cpp
  ../cpp/pdfium/PdfiumFontProvider.cpp
)

if(STROKE_ENGINE_USE_SOURCE)
  target_sources(ReactNativeInkSignPdf PRIVATE
    ${INKSIGN_STROKE_ENGINE_SOURCES}
    ${INKSIGN_UPSTREAM_OUTPUT_SOURCES})
endif()

target_include_directories(ReactNativeInkSignPdf PRIVATE
  ../cpp
  ..
  "${PDFIUM_ROOT}/include"
)

target_compile_features(ReactNativeInkSignPdf PRIVATE cxx_std_20)
target_compile_definitions(ReactNativeInkSignPdf PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)
if(STROKE_ENGINE_USE_SOURCE)
  set(STROKE_ENGINE_LINK_TARGETS UpstreamStrokeGeometry)
else()
  set(STROKE_ENGINE_LINK_TARGETS StrokeEngineBundle)
endif()
target_link_libraries(ReactNativeInkSignPdf
  android
  jnigraphics
  PDFium
  ${STROKE_ENGINE_LINK_TARGETS}
  c++_shared
)

include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/ReactNativeInkSignPdf+autolinking.cmake)
