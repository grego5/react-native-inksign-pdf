cmake_minimum_required(VERSION 3.22.1)
project(ReactNativeInkSignPdf)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(INKSIGN_REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
set(INKSIGN_INK_ENGINE_ROOT "${INKSIGN_REPO_ROOT}/core/ink-engine")
set(INKSIGN_INK_ENGINE_INCLUDE_DIR "${INKSIGN_INK_ENGINE_ROOT}/include")
set(INKSIGN_PDFIUM_ADAPTER_ROOT "${CMAKE_CURRENT_LIST_DIR}/../core/pdfium-adapter")
option(ENABLE_PERFETTO_TRACE
  "Compile Android Perfetto/ATrace instrumentation into source targets" OFF)
option(INK_ENGINE_USE_SOURCE
  "Build the InkEngine from repository sources instead of the bundled archive" OFF)
set(INK_ENGINE_ARCHIVE_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/build/ink-engine" CACHE PATH
  "Directory containing Gradle-downloaded per-ABI ink-engine archives")
set(INK_ENGINE_EXPECTED_NDK_VERSION "" CACHE STRING
  "Expected NDK version recorded in the bundled ink-engine metadata")
if(MSVC)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /std:c++20 /Zc:__cplusplus")
else()
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++20")
endif()

set(PDFIUM_ROOT "${CMAKE_CURRENT_LIST_DIR}/../core/third_party/pdfium")
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

include(${INKSIGN_INK_ENGINE_ROOT}/InkEngineSources.cmake)

if(INK_ENGINE_USE_SOURCE)
  # Source mode is explicit for repository development and tests. It is kept
  # complete and independent of the packaged archive.
  set(ABSL_PROPAGATE_CXX_STD ON CACHE BOOL "" FORCE)
  set(ABSL_BUILD_TESTING OFF CACHE BOOL "" FORCE)
  add_subdirectory(../core/third_party/abseil-cpp
    ${CMAKE_CURRENT_BINARY_DIR}/abseil-cpp EXCLUDE_FROM_ALL)
  add_subdirectory(../core/third_party/google-ink
    ${CMAKE_CURRENT_BINARY_DIR}/google-ink EXCLUDE_FROM_ALL)

  add_library(UpstreamStrokeGeometry STATIC
    ${INKSIGN_UPSTREAM_GEOMETRY_SOURCES}
  )
  target_link_libraries(UpstreamStrokeGeometry PUBLIC GoogleInkGeometry)
  target_include_directories(UpstreamStrokeGeometry PUBLIC
    ${INKSIGN_INK_ENGINE_ROOT})
  target_compile_features(UpstreamStrokeGeometry PUBLIC cxx_std_20)
  target_compile_definitions(UpstreamStrokeGeometry PRIVATE
    ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)
else()
  set(_ink_engine_supported_abis arm64-v8a x86_64)
  if(NOT ANDROID_ABI IN_LIST _ink_engine_supported_abis)
    message(FATAL_ERROR
      "No downloaded ink-engine archive is supported for Android ABI ${ANDROID_ABI}. "
      "Supported ABIs: ${_ink_engine_supported_abis}")
  endif()

  set(INK_ENGINE_ARCHIVE
    "${INK_ENGINE_ARCHIVE_ROOT}/${ANDROID_ABI}/libinkengine_${ANDROID_ABI}.a")
  set(INK_ENGINE_METADATA "${INK_ENGINE_ARCHIVE}.json")
  if(NOT EXISTS "${INK_ENGINE_ARCHIVE}")
    message(FATAL_ERROR
      "Downloaded ink-engine archive is missing for ${ANDROID_ABI}: "
      "${INK_ENGINE_ARCHIVE}. The Gradle prepareInkEngine task must run "
      "before CMake, or set -DINK_ENGINE_USE_SOURCE=ON for a deliberate "
      "repository source build.")
  endif()
  if(NOT EXISTS "${INK_ENGINE_METADATA}")
    message(FATAL_ERROR
      "Downloaded ink-engine metadata is missing for ${ANDROID_ABI}: "
      "${INK_ENGINE_METADATA}")
  endif()

  file(READ "${INK_ENGINE_METADATA}" _ink_engine_metadata)
  string(JSON _ink_engine_metadata_abi GET "${_ink_engine_metadata}" abi)
  string(JSON _ink_engine_metadata_archive GET "${_ink_engine_metadata}" archive)
  string(JSON _ink_engine_metadata_api GET "${_ink_engine_metadata}" apiVersion)
  string(JSON _ink_engine_metadata_ndk GET "${_ink_engine_metadata}" ndkVersion)
  string(JSON _ink_engine_metadata_trace GET "${_ink_engine_metadata}" perfettoTrace)
  string(JSON _ink_engine_metadata_size GET "${_ink_engine_metadata}" sizeBytes)
  string(JSON _ink_engine_metadata_sha256 GET "${_ink_engine_metadata}" sha256)
  get_filename_component(_ink_engine_archive_name "${INK_ENGINE_ARCHIVE}" NAME)

  file(READ "${INKSIGN_INK_ENGINE_INCLUDE_DIR}/InkEngineC.h" _ink_engine_header)
  string(REGEX MATCH
    "INK_ENGINE_API_VERSION[ \t]+([0-9]+)u?"
    _ink_engine_api_match "${_ink_engine_header}")
  if(NOT CMAKE_MATCH_1)
    message(FATAL_ERROR "Unable to determine the InkEngine C ABI version")
  endif()
  set(_ink_engine_expected_api "${CMAKE_MATCH_1}")

  if(NOT _ink_engine_metadata_abi STREQUAL ANDROID_ABI)
    message(FATAL_ERROR
      "Ink-engine metadata ABI ${_ink_engine_metadata_abi} does not match "
      "Android ABI ${ANDROID_ABI}")
  endif()
  if(NOT _ink_engine_metadata_archive STREQUAL _ink_engine_archive_name)
    message(FATAL_ERROR
      "Ink-engine metadata archive ${_ink_engine_metadata_archive} does not "
      "match ${_ink_engine_archive_name}")
  endif()
  if(NOT _ink_engine_metadata_api STREQUAL _ink_engine_expected_api)
    message(FATAL_ERROR
      "Ink-engine API mismatch: archive has ${_ink_engine_metadata_api}, "
      "consumer requires ${_ink_engine_expected_api}")
  endif()
  if(INK_ENGINE_EXPECTED_NDK_VERSION AND
     NOT _ink_engine_metadata_ndk STREQUAL INK_ENGINE_EXPECTED_NDK_VERSION)
    message(FATAL_ERROR
      "Ink-engine archive was built with NDK ${_ink_engine_metadata_ndk}; "
      "consumer requires ${INK_ENGINE_EXPECTED_NDK_VERSION}")
  endif()
  if(_ink_engine_metadata_trace)
    message(FATAL_ERROR
      "The normal Android consumer cannot link a tracing-enabled stroke archive")
  endif()

  file(SIZE "${INK_ENGINE_ARCHIVE}" _ink_engine_actual_size)
  if(NOT _ink_engine_actual_size EQUAL _ink_engine_metadata_size)
    message(FATAL_ERROR
      "Ink-engine archive size mismatch: metadata says "
      "${_ink_engine_metadata_size}, file is ${_ink_engine_actual_size}")
  endif()
  file(SHA256 "${INK_ENGINE_ARCHIVE}" _ink_engine_actual_sha256)
  if(NOT _ink_engine_actual_sha256 STREQUAL _ink_engine_metadata_sha256)
    message(FATAL_ERROR
      "Ink-engine archive SHA-256 mismatch for ${INK_ENGINE_ARCHIVE}")
  endif()

  add_library(InkEngineBundle STATIC IMPORTED GLOBAL)
  set_target_properties(InkEngineBundle PROPERTIES
    IMPORTED_LOCATION "${INK_ENGINE_ARCHIVE}")
endif()

add_library(ReactNativeInkSignPdf SHARED
  src/main/cpp/cpp-adapter.cpp
  src/main/cpp/pdfium_render_jni.cpp
  src/main/cpp/pdfium_export_jni.cpp
  src/main/cpp/pdfium_smoke.cpp
  src/main/cpp/pdfium_session_smoke.cpp
  src/main/cpp/InkEngineJni.cpp
  ${INKSIGN_PDFIUM_ADAPTER_ROOT}/PdfiumDocumentSession.cpp
  ${INKSIGN_PDFIUM_ADAPTER_ROOT}/PdfiumPageAssembler.cpp
  ${INKSIGN_PDFIUM_ADAPTER_ROOT}/PdfiumFontCoverage.cpp
  ${INKSIGN_PDFIUM_ADAPTER_ROOT}/PdfiumFontFallback.cpp
  ${INKSIGN_PDFIUM_ADAPTER_ROOT}/PdfiumFontProvider.cpp
)

if(INK_ENGINE_USE_SOURCE)
  target_sources(ReactNativeInkSignPdf PRIVATE
    ${INKSIGN_INK_ENGINE_SOURCES}
    ${INKSIGN_UPSTREAM_OUTPUT_SOURCES})
endif()

target_include_directories(ReactNativeInkSignPdf PRIVATE
  ${INKSIGN_REPO_ROOT}
  ${INKSIGN_REPO_ROOT}/core
  ${INKSIGN_INK_ENGINE_ROOT}
  ${INKSIGN_INK_ENGINE_INCLUDE_DIR}
  ${CMAKE_CURRENT_LIST_DIR}/..
  "${PDFIUM_ROOT}/include"
)

target_compile_features(ReactNativeInkSignPdf PRIVATE cxx_std_20)
target_compile_definitions(ReactNativeInkSignPdf PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)
if(INK_ENGINE_USE_SOURCE)
  set(INK_ENGINE_LINK_TARGETS UpstreamStrokeGeometry)
else()
  set(INK_ENGINE_LINK_TARGETS InkEngineBundle)
endif()
target_link_libraries(ReactNativeInkSignPdf
  android
  jnigraphics
  PDFium
  ${INK_ENGINE_LINK_TARGETS}
  log
  c++_shared
)

include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/ReactNativeInkSignPdf+autolinking.cmake)
