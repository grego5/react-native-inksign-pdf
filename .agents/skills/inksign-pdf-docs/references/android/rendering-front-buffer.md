# Android rendering and front buffer

## Completed rendering

- At PDF-session open, the PDF worker groups adjacent drawable non-ASCII
  scalars, preserving only internal whitespace and punctuation, then calls
  `selectContent()` once per grouped span. It copies the selected text and
  `PdfPageTextContent` rectangles before closing the page. These rectangles are
  already top-left page coordinates and provide both placement and replacement
  size; no font size or advance is derived from integer selection boundary
  points. Vertically overlapping fragments from one selected span are clustered
  and unioned into one visual-line rectangle, preserving the complete text for
  one bidi-shaped run. Multiple line clusters are accepted only when explicit
  newline text maps each text portion to one cluster; ambiguous mappings are
  omitted. Each accepted run is shaped once with Android's default sans-serif
  fallback and platform bidi direction. Its text size is fitted from the
  selected rectangle's height and font metrics, its baseline is derived from
  the same metrics, and horizontal fitting is accepted only within a bounded
  scale range. ASCII, whitespace, control, and unavailable scalars remain in
  the shaping context but are painted transparent, so existing source Latin,
  numbers, punctuation, and borders are not doubled. Each display tile applies
  its tile transform and draws intersecting prepared layouts after
  `PdfRendererPreV`; page-turn previews delegate to the same tile renderer.
  Runs retain their prepared transforms, are generation-bound worker state, and
  never enter history, callbacks, or export. Malformed, unresolved, multi-line
  ambiguous, or unusably scaled selected geometry is omitted without failing
  PDF open.
- After a real mutation, copy the borrowed flattened cubic segments and
  contour records into immutable contour values.
- The frame codec reuses owner-local segment objects, contour records, and
  per-contour segment-reference storage across decodes. Two owner-local banks
  keep decoding transactional: an incoming frame is decoded and fully
  validated in the inactive bank before it replaces the published bank, so a
  rejected frame cannot partially mutate the last valid decoded frame. The
  codec decodes scalar coordinates directly and never retains borrowed JNI
  memory; capacity-growth counters are internal JVM-test diagnostics only.
- Validate finite coordinates, ordered in-range contour offsets, source ranges,
  and closed non-empty contours. Live committed frames replace the entire
  retained real contour collection.
- Retain each contour as an independent immutable
  `moveTo`/`cubicTo`/`close` path. The active front buffer presents either the
  complete real contour snapshot or the complete prediction contour snapshot,
  never both; this avoids applying translucent ink twice. Submit each contour
  as a separate fill so opposite winding directions cannot cancel an overlap.
- On successful `Up`, copy the complete final contour collection once into one
  ink entry in the active page's ordered page-content history and independent
  completed RenderNode paths, then release active presentation.
- Ordinary `onDraw` renders PDF tiles, completed batches, and the committed
  page text layer; it does not render active ink. The text layer is derived
  from the active page history and omits the annotation currently owned by the
  temporary native editor.
- Undo removes completed batches and releases their `RenderNode` resources
  when no path references them.
- Front-buffer, prediction, history, and PDF export retain the same native
  cubic commands for ink entries. Completed rendering, final handoff, and PDF
  export submit each contour as its own filled path. Undo removes every
  contour in the last ink entry, reopening sealed completed batches as needed.
  Text entries remain in the same page history and are omitted from the current
  ink projection. Do not use `Path.approximate()` or refit polygons.

## Prediction and presenter lifecycle

- Request AndroidX prediction only for an eligible active stroke.
- Each accepted move `MotionEvent` real batch produces one native committed
  frame and one front-buffer submission. Historical samples are traced
  individually, but frame decoding and committed-frame application happen once
  for the batch. A move batch requests prediction once after that real frame.
  A terminal batch produces one final native mutation, then installs durable
  history and performs final handoff; it is not passed to the committed
  front-buffer composition and never requests prediction.
- Prediction is a complete replaceable presentation snapshot and may be empty.
  Real contours remain retained while prediction is visible and are restored
  when prediction clears. Region filtering happens after choosing the active
  snapshot, so an off-region prediction never causes real fallback paths to be
  submitted.
- Clear prediction before every committed frame and on every terminal path.
- Reject `Down` when the attached presenter is unavailable.
- Presenter loss cancels native input and clears rolling state.
- Keep acknowledgement acceptance separate from presenter generation.
- On `Up`, record the final contour collection, disable the acknowledgement gate, clear
  committed and predicted rolling state, and request final handoff.
- Cancellation, reset, replacement, mode/lifecycle loss, and disposal close the
  gate before clearing rolling state.
- Page switches cancel active input and front-buffer handoff, then replace the
  renderer's completed batches with the ink projection of the target page's
  history. History remains page-local; an active page's state reports its own
  undo/redo flags, while dirty state is aggregated across all pages' committed
  content.
- Reject delayed callbacks from superseded generations or sequences.
- Bound pending work and coalesce only to a self-sufficient latest payload that
  retains all required unacknowledged dirty regions.
- A final handoff releases transient front-buffer state only after a current
  generation completes its HWUI frame.
- The low-latency implementation is intentionally split by ownership:
  contracts and diagnostics, payload mailbox, host/completion boundary, and
  worker draw callback are separate files. Keep the surface view as the
  stateful UI coordinator and keep pure MotionEvent sample normalization in
  its own helper.
- Neighbor previews draw their committed ink before their prepared text layer;
  text layouts are created when a preview request is accepted, not during
  animation frames.
