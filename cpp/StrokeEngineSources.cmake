# Production stroke-engine sources shared by desktop, Android source builds,
# and the Android bundled-archive producer. Keep platform/JNI and PDFium code
# out of this inventory.
set(INKSIGN_STROKE_ENGINE_SOURCES
  ${CMAKE_CURRENT_LIST_DIR}/StrokeEngine.cpp
  ${CMAKE_CURRENT_LIST_DIR}/engine/StrokeEngineInternal.cpp
  ${CMAKE_CURRENT_LIST_DIR}/engine/StrokeEngineProcessing.cpp
  ${CMAKE_CURRENT_LIST_DIR}/engine/StrokeEnginePrediction.cpp
  ${CMAKE_CURRENT_LIST_DIR}/StrokeEngineC.cpp
  ${CMAKE_CURRENT_LIST_DIR}/input/CommittedCenterline.cpp
  ${CMAKE_CURRENT_LIST_DIR}/input/CurrentInkInputModeler.cpp
  ${CMAKE_CURRENT_LIST_DIR}/modeling/ContactLifecycle.cpp
  ${CMAKE_CURRENT_LIST_DIR}/input/InputNormalizer.cpp
  ${CMAKE_CURRENT_LIST_DIR}/modeling/VelocityWidthModel.cpp
  ${CMAKE_CURRENT_LIST_DIR}/modeling/SignatureBrushTipModeler.cpp
)

set(INKSIGN_UPSTREAM_GEOMETRY_SOURCES
  ${CMAKE_CURRENT_LIST_DIR}/upstream/UpstreamStrokeGeometry.cpp
)

set(INKSIGN_UPSTREAM_OUTPUT_SOURCES
  ${CMAKE_CURRENT_LIST_DIR}/upstream/UpstreamStrokeOutput.cpp
)
