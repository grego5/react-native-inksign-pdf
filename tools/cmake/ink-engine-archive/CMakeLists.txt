cmake_minimum_required(VERSION 3.22)

project(ReactNativeInkSignInkEngineArchive LANGUAGES C CXX)

if(NOT ANDROID)
  message(FATAL_ERROR
    "The bundled stroke archive must be configured with the Android NDK toolchain.")
endif()
if(NOT ANDROID_ABI)
  message(FATAL_ERROR "ANDROID_ABI is required, for example arm64-v8a.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Archive build configuration" FORCE)
endif()

option(ENABLE_PERFETTO_TRACE
  "Compile Android Perfetto/ATrace instrumentation into the archive" OFF)
set(INK_ENGINE_ARCHIVE_OUTPUT_DIRECTORY
  "${CMAKE_BINARY_DIR}/artifacts" CACHE PATH
  "Directory receiving the archive and metadata")
set(INK_ENGINE_ARCHIVE_NAME
  "libinkengine_${ANDROID_ABI}.a" CACHE STRING
  "Bundled archive filename")
set(INK_ENGINE_NDK_PATH "" CACHE PATH
  "Android NDK root used for archive metadata")

get_filename_component(INKSIGN_REPO_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(INKSIGN_INK_ENGINE_ROOT "${INKSIGN_REPO_ROOT}/core/ink-engine")
set(INKSIGN_INK_ENGINE_INCLUDE_DIR "${INKSIGN_INK_ENGINE_ROOT}/include")
include(${INKSIGN_INK_ENGINE_ROOT}/InkEngineSources.cmake)

set(ABSL_PROPAGATE_CXX_STD ON CACHE BOOL "" FORCE)
set(ABSL_BUILD_TESTING OFF CACHE BOOL "" FORCE)
add_subdirectory(${INKSIGN_REPO_ROOT}/core/third_party/abseil-cpp
  ${CMAKE_BINARY_DIR}/third_party/abseil-cpp EXCLUDE_FROM_ALL)
add_subdirectory(${INKSIGN_REPO_ROOT}/core/third_party/google-ink
  ${CMAKE_BINARY_DIR}/third_party/google-ink EXCLUDE_FROM_ALL)

add_library(UpstreamStrokeGeometry STATIC ${INKSIGN_UPSTREAM_GEOMETRY_SOURCES})
target_link_libraries(UpstreamStrokeGeometry PUBLIC GoogleInkGeometry)
target_include_directories(UpstreamStrokeGeometry PUBLIC ${INKSIGN_INK_ENGINE_ROOT})
target_compile_features(UpstreamStrokeGeometry PUBLIC cxx_std_20)
target_compile_definitions(UpstreamStrokeGeometry PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)

add_library(UpstreamStrokeOutput STATIC ${INKSIGN_UPSTREAM_OUTPUT_SOURCES})
target_link_libraries(UpstreamStrokeOutput PUBLIC UpstreamStrokeGeometry)
target_include_directories(UpstreamStrokeOutput PUBLIC ${INKSIGN_INK_ENGINE_ROOT})
target_compile_features(UpstreamStrokeOutput PUBLIC cxx_std_20)

add_library(InkEngine STATIC ${INKSIGN_INK_ENGINE_SOURCES})
target_link_libraries(InkEngine PUBLIC UpstreamStrokeOutput)
target_include_directories(InkEngine PUBLIC
  ${INKSIGN_INK_ENGINE_INCLUDE_DIR}
  ${INKSIGN_INK_ENGINE_ROOT}
  ${INKSIGN_REPO_ROOT}/core)
target_include_directories(InkEngine PRIVATE ${INKSIGN_REPO_ROOT})
target_compile_features(InkEngine PUBLIC cxx_std_20)
target_compile_definitions(InkEngine PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
  target_compile_options(InkEngine PRIVATE -Wall -Wextra -Wpedantic)
endif()

set(INK_ENGINE_ARCHIVE
  "${INK_ENGINE_ARCHIVE_OUTPUT_DIRECTORY}/${INK_ENGINE_ARCHIVE_NAME}")
set(INK_ENGINE_METADATA
  "${INK_ENGINE_ARCHIVE_OUTPUT_DIRECTORY}/${INK_ENGINE_ARCHIVE_NAME}.json")

execute_process(
  COMMAND git -C ${INKSIGN_REPO_ROOT} rev-parse HEAD
  OUTPUT_VARIABLE INK_ENGINE_SOURCE_REVISION
  OUTPUT_STRIP_TRAILING_WHITESPACE
  ERROR_QUIET
  RESULT_VARIABLE INK_ENGINE_GIT_RESULT)
if(NOT INK_ENGINE_GIT_RESULT EQUAL 0)
  set(INK_ENGINE_SOURCE_REVISION "unknown")
endif()

file(READ ${INKSIGN_INK_ENGINE_INCLUDE_DIR}/InkEngine.hpp INK_ENGINE_HEADER)
string(REGEX MATCH
  "kInkEngineApiVersion[ \\t]*=[ \\t]*([0-9]+)"
  INK_ENGINE_API_MATCH ${INK_ENGINE_HEADER})
if(NOT CMAKE_MATCH_1)
  message(FATAL_ERROR "Unable to read the ink-engine C API version.")
endif()
set(INK_ENGINE_API_VERSION ${CMAKE_MATCH_1})

set(INK_ENGINE_TOOLCHAIN
  "${CMAKE_SYSTEM_NAME};${CMAKE_CXX_COMPILER_ID};${CMAKE_CXX_COMPILER_VERSION};${CMAKE_CXX_COMPILER_TARGET}")
set(INK_ENGINE_NDK_VERSION "${CMAKE_ANDROID_NDK_VERSION}")
if(NOT INK_ENGINE_NDK_VERSION AND DEFINED CMAKE_ANDROID_NDK)
  set(INK_ENGINE_NDK_PATH "${CMAKE_ANDROID_NDK}")
endif()
if(INK_ENGINE_NDK_PATH AND
   EXISTS "${INK_ENGINE_NDK_PATH}/source.properties")
  file(READ "${INK_ENGINE_NDK_PATH}/source.properties"
    INK_ENGINE_NDK_PROPERTIES)
  string(REGEX MATCH
    "Pkg.Revision[ \\t]*=[ \\t]*([0-9.]+)"
    INK_ENGINE_NDK_VERSION_MATCH ${INK_ENGINE_NDK_PROPERTIES})
  if(CMAKE_MATCH_1)
    string(STRIP "${CMAKE_MATCH_1}" INK_ENGINE_NDK_VERSION)
  endif()
endif()

add_custom_command(
  OUTPUT ${INK_ENGINE_ARCHIVE} ${INK_ENGINE_METADATA}
  COMMAND ${CMAKE_COMMAND}
    -DOUTPUT=${INK_ENGINE_ARCHIVE}
    -DMETADATA=${INK_ENGINE_METADATA}
    -DAR=${CMAKE_AR}
    -DRANLIB=${CMAKE_RANLIB}
    "-DPRIMARY_ARCHIVES=$<TARGET_FILE:InkEngine>;$<TARGET_FILE:UpstreamStrokeOutput>;$<TARGET_FILE:UpstreamStrokeGeometry>;$<TARGET_FILE:GoogleInkGeometry>"
    -DABSL_ARCHIVE_ROOT=${CMAKE_BINARY_DIR}/third_party/abseil-cpp
    -DABI=${ANDROID_ABI}
    -DAPI_VERSION=${INK_ENGINE_API_VERSION}
    -DSOURCE_REVISION=${INK_ENGINE_SOURCE_REVISION}
    "-DTOOLCHAIN=${INK_ENGINE_TOOLCHAIN}"
    -DNDK_VERSION=${INK_ENGINE_NDK_VERSION}
    -DENABLE_PERFETTO_TRACE=${ENABLE_PERFETTO_TRACE}
    -P ${INKSIGN_REPO_ROOT}/tools/cmake/MergeStaticArchives.cmake
  DEPENDS InkEngine UpstreamStrokeOutput UpstreamStrokeGeometry
          GoogleInkGeometry
  VERBATIM)

add_custom_target(InkEngineArchive ALL
  DEPENDS ${INK_ENGINE_ARCHIVE} ${INK_ENGINE_METADATA})

add_library(InkEngineBundle STATIC IMPORTED GLOBAL)
set_target_properties(InkEngineBundle PROPERTIES
  IMPORTED_LOCATION ${INK_ENGINE_ARCHIVE}
  INTERFACE_INCLUDE_DIRECTORIES ${INKSIGN_INK_ENGINE_INCLUDE_DIR})
add_dependencies(InkEngineBundle InkEngineArchive)

add_library(InkEngineArchiveSmoke SHARED
  ${INKSIGN_REPO_ROOT}/tools/ink_engine_archive_smoke.cpp)
target_include_directories(InkEngineArchiveSmoke PRIVATE
  ${INKSIGN_INK_ENGINE_INCLUDE_DIR}
  ${INKSIGN_INK_ENGINE_ROOT})
target_compile_features(InkEngineArchiveSmoke PRIVATE cxx_std_20)
target_link_libraries(InkEngineArchiveSmoke PRIVATE
  InkEngineBundle android log c++_shared)
target_link_options(InkEngineArchiveSmoke PRIVATE -Wl,--no-undefined)
add_dependencies(InkEngineArchiveSmoke InkEngineArchive)
