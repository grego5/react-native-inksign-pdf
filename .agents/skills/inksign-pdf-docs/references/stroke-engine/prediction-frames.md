# Prediction and frames

## Prediction contract

- Prediction starts from bounded recent real context and copied model state. It
  is limited to 64 compatible future samples.
- Each real move batch clears the old prediction and evaluates a new one from
  the final accepted real state. Prediction submits no new fixed geometry and
  never changes width state, seam checkpoints, history, undo/redo, export, or
  replay.
- A prediction frame contains the replaceable real tail followed by predicted
  geometry. An empty or incompatible prediction produces no preview.
- Live and final frames contain complete contour snapshots. Platform adapters
  copy frames before the next engine call and only transform the authoritative
  page-space cubics for display; they do not rebuild caps, joins, taper, or
  smoothing.
- Final publication clears prediction state. All published paths remain closed
  and retain their source ranges for replacement and diagnostics.
