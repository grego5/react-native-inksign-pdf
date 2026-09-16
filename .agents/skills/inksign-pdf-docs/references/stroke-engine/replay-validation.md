# Replay and validation

## Replay

- Replay operations are `down`, `move`, `up`, and `cancel`, with optional frozen
  pen metadata.
- Replay feeds accepted page-space input through `StrokeEngine` and applies
  published contour suffix deltas.
- It records the production final contour collection and does not implement a
  second geometry, taper, cap, width, or smoothing formula.
- Diagnostics CSV v10 records raw display speed, unbounded effective display
  speed, turn factor, temporal delta and alpha, speed-derived target radius,
  modeled radius, consecutive modeled segment distance, per-sample radius
  change limit, limited target radius, post-taper final radius, and source
  identities. Reference-selection, temporal-filter, solver, work-counter, and
  startup-hold fields are absent.
- Envelope CSV v1 reports offline sampled measurements from final published cubics.
  Replay selects at most 256 ordered real modeled centers, including endpoints when
  available, and uses local tangents and running arclength. Widening-phase labels
  request width-trend observations only; they are not a startup monotonicity rule,
  terminal classification or a silhouette guarantee. Degenerate sections are omitted.
- Independent finite cubic sampling unions separately filled contour intervals and
  cross-checks corresponding section widths. Missing/ambiguous comparisons report
  Unsupported, not passing evidence. Discrepancies exceeding the existing 0.05-page-
  unit tolerance fail replay invariants. No continuous certification is claimed.
- Measurement runs only in replay/tests. The production engine does not build
  measurement sections, evaluate cubics for startup selection, or search radii.
- Replay emits exact first-moving, last-nonterminal, and final contour snapshots
  per completed stroke, with zoomed companions when those frames exist. Filenames include the
  one-based stroke ID and source operation ID as
  `<name>-stroke-<stroke>-<stage>-op-<operation>.svg`; each SVG also carries the
  same identifiers in its title. Snapshot selection is scoped to that stroke,
  so a missing first-moving or last-nonterminal frame is not borrowed from another stroke. The
  SVGs use the published contour collection and do not draw a replacement
  outline.
- Routine fixture checks can use `npm run test:stroke:fast -- INPUT.csv`.
  The harness keeps the fixture on disk, invokes the built replay CLI with
  invariant validation and compact reference/geometry metrics, and skips artifact
  generation. Use `-- --config release INPUT.csv` for the Release build; run
  the full artifact path only when CSV/SVG inspection is needed.
- A CSV `# pen,min_width,max_width,smoothing,display_scale` row is replay metadata.
  Each matching CLI option accepts `current`, `recorded`, or a numeric value;
  omitted options default to `current`. For example, deterministic smoothing A/B
  on one capture uses `--smoothing 0.4` and `--smoothing 0.8`, while
  `--smoothing recorded --min-width recorded` opts into selected capture values
  without editing the fixture.
- Replay implementation is split by responsibility: `StrokeReplay.cpp` owns
  operation parsing and production-state reconstruction, `StrokeReplayCsv.cpp`
  owns tabular artifact emission, `StrokeReplayValidation.cpp` owns
  published-geometry evidence and calibration aggregation, and
  `StrokeReplaySvg.cpp` owns visual artifact generation. Engine state ownership
  lives in `engine/StrokeEngineInternal.*`; lifecycle wrappers remain in
  `StrokeEngine.cpp`. `modeling/SignatureBrushTipModeler.*` owns real/predicted
  width processing, checkpoints, fixation and tip materialization.
  `engine/StrokeEngineProcessing.cpp` owns extrusion submission
  and frame publication; `engine/StrokeEnginePrediction.cpp` owns prediction
  admission and disposable frame construction. Geometry timing includes brush
  tip modeling/materialization and upstream extrusion; model timing covers
  centerline work. The public engine header does not expose these implementation
  boundaries.

## Tests

- Native tests cover input lifecycle, contour replacement ranges,
  completed-contour immutability, width response, taper, upstream geometry,
  prediction purity, frame publication, transport, replay determinism, native
  live-work counters, and performance bounds.
- Offline envelope measurement remains a replay diagnostic; it has no production
  geometry target or runtime dependency.
- Platform tests cover frame decoding, suffix application, history ownership,
  and final-outline reconstruction.
- Run repository checks from [development.md](../development.md).
- Report unavailable Android, iOS, or MSVC tooling; do not change the engine
  contract for a host-only environment.

## Engine invariants

- Keep the engine page-space and toolkit-neutral.
- Keep high-frequency input, modeled state, and geometry native.
- Keep prediction bounded and presentation-only.
- Keep one authoritative real centerline and one authoritative real contour
  collection.
