# Replay and validation

Replay uses the production stroke engine; it is not a second implementation of
width, taper, caps, smoothing, or geometry.

Replay accepts `down`, `move`, `up`, and `cancel` operations and emits
diagnostics from the published production contours.


## Tests and invariants

- Use `npm run test:stroke:fast -- INPUT.csv` for routine fixture replay. Run
  the full artifact path only when CSV or SVG inspection is needed.
- Native tests cover lifecycle, replacement, width/taper behavior, geometry,
  prediction purity, frame publication, replay determinism, and platform frame
  consumption.
- Offline envelope measurement is diagnostic evidence only; it does not certify
  a continuous silhouette and is not linked into production geometry.
- Keep the engine page-space and toolkit-neutral. Input, modeled state, and
  geometry remain native; prediction stays bounded and presentation-only; one
  real centerline and one real contour collection remain authoritative.
- Use the repository checks in [development.md](../development.md), and report
  unavailable platform toolchains instead of changing the engine contract.
