# Circular-tip provenance

`cpp/circular/StartupEnvelope.cpp` is a diagnostic-only replay evaluator. It
is not linked into production geometry and never constructs or repairs the
published contours.

Production modeling uses `SignatureBrushTipModeler` and the upstream
`BrushTipExtruder`. The circular tip uses a fully rounded, neutral brush
definition; production contours come from the upstream extruder, not from a
custom circular-geometry backend. Width behavior is repository-owned and is
documented in [styling.md](styling.md), not treated as a Google Ink setting or
binary clone.

The adaptation is informed by locally inspected Google Ink material under the
Apache License 2.0. No Google Ink source files are compiled into the repository
target.
