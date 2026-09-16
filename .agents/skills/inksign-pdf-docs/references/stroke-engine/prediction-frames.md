# Prediction and frames

## Prediction

- Prediction is presentation-only and starts from bounded recent real context
  plus copied semantic width state.
- `SignatureBrushTipModeler::predict` copies semantic width recurrence state and
  derives a local terminal-style snapshot. It reuses owner-local preview points
  and tip storage, leaving real seam snapshots, fixation and work counters
  untouched. The engine submits the split to the same upstream geometry owner
  used by real input and publishes a disposable owned outline snapshot.
  Prediction emits no new fixed upstream states: its volatile span contains the
  complete replaceable real tail followed by predicted states.
- Real Android moves are admitted through a bounded ordered batch; prediction
  is cleared before the batch and evaluated once from its final accepted real
  state. The terminal batch publishes no prediction replacement.
- The permanent modeler, stable frontier, real width state, terminal speed,
  final geometry, history, undo/redo, export, and replay remain unchanged.
- Each replacement starts from real state; the previous prediction is discarded.
- Real/predicted upstream spans are split at the modeled source seam, not by
  outline count. Prediction cannot replace consumed fixed sources.
- Empty/unavailable prediction produces no preview and does not affect the real
  stroke.
- Prediction is bounded at 64 samples and requires later `Move` timestamps with
  compatible stylus attributes.
- Prediction geometry copies real style, causal width-recurrence state, modeled
  points, and upstream owner state. It materializes taper and publishes a complete
  disposable snapshot through upstream outline extraction. Prediction cannot
  mutate real recurrence state or seam checkpoints. No startup solver or
  separate geometry-lock state is copied or evaluated.
- The centerline owns a reusable prediction modeler and conversion buffers for
  bounded recent-context replacement; the committed modeler remains untouched.
  The resulting snapshot remains disposable and is copied into the caller-owned
  prediction frame before the next replacement. It is never admitted to
  committed history.

## Frame types

- Live committed frames contain the complete active contour snapshot.
- Prediction frames contain a complete disposable outline snapshot, including
  the replaceable real tail and predicted tip geometry.
- Final frames contain the complete modeled centerline and contour collection,
  not live deltas.
- Frame vectors are copied by platform adapters before the next engine call.
- Platforms transform page-space cubics for display and retain complete cubics
  for history/export. They do not rebuild smoothing, joins, taper, or caps.
- Every published contour path is closed and carries source ranges on its
  segments. Upstream mesh edges are represented as exact collinear cubic
  transport segments; a one-point final stroke remains owned by upstream.
- Diagnostics snapshot real, modeled, predicted, geometry, and timing state;
  they are not another stroke representation.
- Final frames clear prediction validity and counts.
