# Android rendering and front buffer

## Completed rendering

The PDF worker prepares shared PDFium positioned-text snapshots lazily and
keeps the existing heuristic compatibility layouts as the presentation
fallback during migration. Both are presentation-only, generation-bound, and
excluded from history, callbacks, and export. Ambiguous or unusable source
geometry is omitted without failing PDF open.
The frame codec copies borrowed JNI data into immutable contour values, validates
finite coordinates, source ranges, ordered offsets, and closed non-empty paths,
then replaces the retained real snapshot transactionally.
The front buffer presents either the complete real contour snapshot or the
complete prediction snapshot, never both. Each contour remains an independent
closed fill path, and the same native cubics are used for display, history, and
export. Completed ink is committed once on `Up`; active ink is not drawn by
ordinary `onDraw`.

## Prediction and presenter lifecycle

- Each accepted move batch produces one committed frame, then at most one
  replaceable prediction snapshot. A terminal batch produces the final frame,
  commits history, and performs final handoff without requesting prediction.
- Prediction is presentation-only and may be empty. Clear it before committed
  frames and on terminal, cancellation, reset, replacement, presenter-loss,
  mode, or disposal paths.
- Reject input when the presenter is unavailable. Accept callbacks only for the
  current generation/sequence, and keep pending work bounded.
- Page switches cancel active input and handoff, then rebuild completed display
  from the target page's history. History remains page-local; dirty state spans
  the document.
