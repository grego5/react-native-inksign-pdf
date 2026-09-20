cmake_minimum_required(VERSION 3.22.1)
project(ReactNativeInkSignPdf)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
option(ENABLE_PERFETTO_TRACE
  "Compile Android Perfetto/ATrace instrumentation into source targets" OFF)
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

# Build the upstream stroke geometry owner and its output adapter into the
# Android native target.
set(ABSL_PROPAGATE_CXX_STD ON CACHE BOOL "" FORCE)
set(ABSL_BUILD_TESTING OFF CACHE BOOL "" FORCE)
add_subdirectory(../third_party/abseil-cpp
  ${CMAKE_CURRENT_BINARY_DIR}/abseil-cpp EXCLUDE_FROM_ALL)
add_subdirectory(../third_party/google-ink
  ${CMAKE_CURRENT_BINARY_DIR}/google-ink EXCLUDE_FROM_ALL)

include(${CMAKE_CURRENT_LIST_DIR}/../cpp/StrokeEngineSources.cmake)

add_library(UpstreamStrokeGeometry STATIC
  ${INKSIGN_UPSTREAM_GEOMETRY_SOURCES}
)
target_link_libraries(UpstreamStrokeGeometry PUBLIC GoogleInkGeometry)
target_include_directories(UpstreamStrokeGeometry PUBLIC ../cpp)
target_compile_features(UpstreamStrokeGeometry PUBLIC cxx_std_20)
target_compile_definitions(UpstreamStrokeGeometry PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)

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
  ${INKSIGN_STROKE_ENGINE_SOURCES}
  ${INKSIGN_UPSTREAM_OUTPUT_SOURCES}
)

target_include_directories(ReactNativeInkSignPdf PRIVATE
  ../cpp
  ..
  "${PDFIUM_ROOT}/include"
)

target_compile_features(ReactNativeInkSignPdf PRIVATE cxx_std_20)
target_compile_definitions(ReactNativeInkSignPdf PRIVATE
  ENABLE_PERFETTO_TRACE=$<BOOL:${ENABLE_PERFETTO_TRACE}>)
target_link_libraries(ReactNativeInkSignPdf
  android
  jnigraphics
  PDFium
  UpstreamStrokeGeometry
  c++_shared
)

include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/ReactNativeInkSignPdf+autolinking.cmake)
