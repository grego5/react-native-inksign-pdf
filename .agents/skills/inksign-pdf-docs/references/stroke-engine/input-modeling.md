# Input and modeling

## Boundary

- StrokeEngine owns page-space modeling and delegates input normalization,
  centerline modeling, styling, and upstream geometry to the focused engine
  components.
- The engine is synchronous, caller-owned, and independent of React Native,
  UIKit, Android, and PDF I/O.
- C ABI frames and upstream views are borrowed. Platform callers materialize
  anything they need after the next engine operation.

## Input admission

- StrokeInput contains Down, Move, or Up, a finite page-space position, a
  monotonic timestamp in seconds, and optional pressure, tilt, and orientation.
- Normalization enforces event order, rejects invalid values, duplicate tuples,
  backwards timestamps, and incompatible stylus seams. Distinct equal-time
  movement is valid but cannot produce finite velocity.
- Stroke configuration is validated before a contact and remains fixed while
  it is active. Invalid values are rejected rather than clamped, swapped, or
  defaulted. Platform adapters freeze display-to-page scale and derived page
  widths at Down.
- updateBatch and endBatch validate the complete bounded span against a value
  snapshot before committing it. A rejected batch leaves counts, model state,
  frontiers, and replacement state unchanged; an accepted batch models once
  and produces one replacement.

## Centerline

- CommittedCenterline adapts the Google Ink sliding-window model. Smoothing
  maps to a 0...25 ms centered window; 0.4 is 10 ms and 0 is raw passthrough.
- Sparse input is upsampled to at most 180 Hz, modeled duplicate positions are
  removed, and velocity/acceleration are derived from the same modeled
  trajectory. Every published state has finite position, derivatives, time,
  stylus metadata, and both raw-source and stable-modeled identities.
- Real input is retained. Each update preserves the immutable modeled prefix,
  remakes only the recent unstable context, and publishes a complete active
  contour snapshot. Work after the centered window fills is bounded by that
  context rather than total stroke length.
- A modeled state becomes stable only after three smoothing half-windows of
  authoritative future input: position, centered velocity, and centered
  acceleration. The stable frontier is monotonic and published samples are
  immutable.

## Incremental replacement

- The replacement metadata identifies the stable input frontier, the start of
  the current real replacement suffix, and the modeled/radius suffix in the
  committed frame. Append-only updates are valid only when the replacement
  start equals the committed modeled-point count.
- At the seam, the engine restores a value-owned width checkpoint, submits the
  fixed prefix and one complete volatile suffix to upstream geometry, and
  publishes the extracted contour snapshot. Upstream geometry is not assumed
  to have one outline or vertex per input sample.
- The fixed prefix is the intersection of model stability, available width
  checkpoints, and taper-safe remaining arclength. A replacement before the
  accepted upstream frontier is an engine error; the stroke is not silently
  reset or replayed. See geometry.md for upstream outline ownership.

## Contact lifecycle

- Down starts a provisional contact. A stationary release produces one
  canonical upstream dot contour.
- cancel() clears input, width, geometry, frame, and revision state. Prediction
  is disposable and presentation-only; its replacement contract is documented
  in prediction-frames.md.
