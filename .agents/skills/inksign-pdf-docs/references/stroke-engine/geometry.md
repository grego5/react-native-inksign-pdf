# Outline geometry

## Output contract

- `UpstreamStrokeGeometry` is the production geometry owner. It extrudes brush
  tips, handles closure/intersections/taper, and may produce multiple outlines
  for one input sample.
- `StrokeContour` transports closed, ordered cubic paths with source coverage.
  Published cubics are authoritative for live rendering, history, replay, and
  export; construction-only tangent or arc data is not another representation.
- Live, prediction, and final frames use detached complete contour snapshots.
  Platform adapters copy them before the next engine call and do not rebuild
  caps, joins, taper, or smoothing.

## Diagnostics

`StartupEnvelopeEvaluator` is linked only into test/replay tooling. It measures
published cubics at selected sections and reports `NoViolationAtSections`,
`Violation`, or `Unsupported`; it does not build or repair production geometry
and cannot certify a continuous silhouette.

Incremental updates keep a stable prefix and replace only the volatile suffix.
Every published revision replaces the complete active contour snapshot, and
prediction advances only copied real state.
