# Circular-tip provenance

- `SignatureBrushTipModeler` supplies the repository-owned circular brush and
  velocity-width behavior; see [styling](styling.md).
- Production `UpstreamStrokeGeometry` links `GoogleInkGeometry` from
  `core/third_party/google-ink`. Its `BrushTipExtruder` constructs contours.
  Preserve upstream license/provenance notices when changing the adaptation.
- `core/ink-engine/replay-tool/circular/StartupEnvelope.cpp` is diagnostic-only.
  Measurement scope: [geometry](geometry.md#diagnostics).