# Input and modeling

## Boundary and input admission

- `StrokeEngine` owns synchronous page-space modeling and is independent of
  React Native, UIKit, Android, and PDF I/O. Platform callers copy borrowed
  frames and upstream views before the next engine operation.
- Input events are `Down`, `Move`, `Up`, or `Cancel` with finite page-space
  positions, monotonic timestamps, and optional stylus metadata.
- Admission enforces contact order, valid values, compatible stylus seams, and
  non-duplicate input. Configuration and display-to-page scale are frozen at
  `Down`; invalid configuration is rejected rather than silently corrected.
- Move/end batches are validated atomically. A rejected batch changes no engine
  state; an accepted batch is modeled once and produces one replacement.

## Centerline

- `CommittedCenterline` uses a centered smoothing window. It derives position,
  velocity, and acceleration from the same modeled trajectory and removes
  duplicate modeled positions.
- Real input is retained. Updates preserve the immutable modeled prefix and
  rebuild only the recent unstable context, so work remains bounded by that
  context rather than total stroke length.
- The stable frontier advances monotonically. Published stable states are
  immutable and carry the source identity needed for replacement.

## Incremental replacement

- Replacement metadata identifies the stable input frontier and the current
  real suffix. At the seam, the engine restores a width checkpoint, submits
  the fixed prefix plus one complete volatile suffix, and publishes a complete
  contour snapshot.
- A replacement before the accepted upstream frontier is an engine error; the
  stroke is not silently reset or replayed. Upstream geometry may produce more
  than one outline for an input sample; see [geometry.md](geometry.md).

## Contact lifecycle

- `Down` starts a provisional contact. A stationary release produces one
  canonical upstream dot contour.
- `Cancel` clears input, width, geometry, frame, and revision state. Prediction
  remains disposable and presentation-only; see [prediction-frames.md](prediction-frames.md).
