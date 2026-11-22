# Production ink-engine sources shared by desktop, Android source builds,
# and the Android bundled-archive producer. Keep platform/JNI and PDFium code
# out of this inventory.
set(INKSIGN_INK_ENGINE_SOURCES
  ${CMAKE_CURRENT_LIST_DIR}/InkEngine.cpp
  ${CMAKE_CURRENT_LIST_DIR}/engine/InkEngineInternal.cpp
  ${CMAKE_CURRENT_LIST_DIR}/engine/InkEngineProcessing.cpp
  ${CMAKE_CURRENT_LIST_DIR}/engine/InkEnginePrediction.cpp
  ${CMAKE_CURRENT_LIST_DIR}/InkEngineC.cpp
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
