# Outline geometry

## Production path

- `UpstreamStrokeGeometry` is the production geometry owner. It incrementally
  extrudes modeled `BrushTipState` spans into an upstream mesh and outline
  collection, including upstream constraint, rejection, taper and intersection
  behavior.
- `UpstreamStrokeOutput` synchronously reads the owner's borrowed `mesh()` and
  `outlines()` views and materializes them into owned contours before
  publishing. The borrowed views do not escape extraction. Each non-empty
  `StrokeOutline::GetIndices()` sequence becomes one closed path in supplied
  order. The existing cubic transport encodes every mesh edge as exact
  collinear controls; it does not fit curves or construct a second geometry
  representation. Callers that already need retained upstream geometry can use
  the snapshot overload.
- Fixed and volatile upstream input are submitted separately. The modeler’s
  consumed-source frontier determines which states are permanent and which
  remain replaceable; prediction repeats the full replaceable real tail before
  adding predicted states.
- Reset and finish clear the logical coverage vectors while retaining their
  storage capacity; capacity-growth diagnostics remain separate from logical
  retained-state high-water counts.
- The upstream owner owns fixed and volatile input state, mesh mutation,
  outline partitions, bounds, prediction replacement and reset. Published live
  frames are complete replaceable snapshots with no immutable active contour
  prefix; final frames use the same extracted geometry.
- Terminal materialization retains the ordinary endpoint as the final state,
  attenuated continuously by the last valid moving speed. At slow lift-off it
  remains the actual terminal width; faster lift-off produces a finer rounded
  point down to a small positive floor derived from the configured minimum
  radius, without introducing a separate terminal state. Upstream owns
  closure, overlap and intersection handling.
- A caller-owned frame receives detached path snapshots. Live frames replace the
  complete active collection, while final frames and history retain that same
  extracted geometry.
- `SignatureBrushTipModeler` converts only the retained mutable modeled suffix to
  upstream brush-tip states, applies the terminal envelope using monotonic
  modeled arclength, and submits newly fixed states plus the volatile suffix.
  `StrokeEngine` submits the returned spans to the upstream owner and publishes
  the extracted snapshot for live updates. Moving finish consumes those spans,
  copies the complete brush-owned modeled sequence, and performs one final
  extraction before reset clears logical brush state. Dot and terminal contact
  materialization belong to upstream.
- Moving strokes use one authoritative center/radius sequence. The first circle
  supplies the rounded nose and side tangencies and starts at the modeled
  minimum radius; subsequent states use the symmetric distance response described
  in [styling.md](styling.md). Post-taper states pass directly to upstream
  extrusion. There is no startup reference selector, radius search or separate
  geometry lock.
  Containment may hide a circle without deleting its modeled identity or coverage.
- Styling is applied only to the submitted mutable suffix. Body radius comes
  from the velocity width model and terminal attenuation uses the suffix's
  reverse arclength accumulation with `effectiveDistance =
  min(speedScaledTail, totalArcLength)`. The ordinary radius at each point is
  attenuated in place, so body width variation is preserved and the first
  circular state's radius remains unchanged as a prefix grows.

## Live-work diagnostics

- Native `StrokeWorkStats` counters report styled states, materialized tip
  states, reused immutable states, boundary searches, modeler
  and centerline scratch growth, and native C-frame flattening growth. They are
  diagnostic-only and are not
  exposed through JavaScript or the C ABI.
  Prediction uses copied state and does not mutate these committed-work
  counters.

## Cubic contract

- `CubicSegment`, `CubicPath`, and `StrokeContour {path, sourceStart,
  sourceEnd}` in `cpp/core/StrokeOutline.hpp` are the toolkit-neutral transport
  types for upstream output.
- Each contour path is closed, ordered, deterministic, and carries source
  coverage on the contour and its cubic segments.
- Published cubics are authoritative for live rendering, history, replay, and
  export. Analytic tangent and arc data exists only during construction.

## Offline contour measurement

- StartupEnvelopeEvaluator is linked only into test/replay tooling. It measures
  actual published cubic contours at caller-supplied centerline sections; it does
  not construct another outline or participate in production decisions.
- Sampled evidence distinguishes NoViolationAtSections, Violation and Unsupported.
  Unsupported intersections or work limits are not passing evidence. Finite local
  section observations cannot certify a continuously neck-free silhouette.
- Crossing/interval scratch is owner-local. Production engine, Android and iOS
  source lists do not include the evaluator.

## Incremental geometry

- Fixation uses the immutable modeled/width prefix and taper-safe arclength,
  without a reference-lock or additional solver gate. Finish uses the same
  materialization and geometry; prediction advances only copied real state.

- Live output replaces the complete owned active contour snapshot on every
  published frame. Moving termination publishes only its final snapshot.
  Prediction uses the same upstream owner after submitting zero new fixed
  states, so its output includes the full replaceable real tail followed by
  predicted geometry.
- Each published committed frame advances the native revision; consumers use
  that revision to identify the latest replacement snapshot.
- Repeated equivalent live updates may grow owner storage only when a bounded
  high-water mark is first crossed. After representative warmup, modeler and
  centerline scratch growth remain zero for equal-or-smaller workloads.
  Caller-owned replacement frames
  retain their exact logical sizes and authoritative cubic bytes.
