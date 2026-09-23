# Android rendering and front buffer

## PDF pages

- The PDF worker uses one worker-owned PDFium session to render page tiles and
  navigation previews into Android `ARGB_8888` bitmaps. No second renderer or
  text overlay repairs the page image.
- PDFium handles PDF-to-display Y conversion. Android supplies the positive
  display scale and tile offset. The native bridge handles bitmap byte order.
- Android owns tile scheduling, cache keys, document generations,
  cancellation, and preview lifetime.
- Embedded PDF fonts remain PDFium-owned. When the app supplies a fallback
  font, the document session retains its immutable bytes and offers it for
  non-embedded font requests without requiring complete character coverage.
  Unsupported glyphs may remain missing. Without a supplied font, requests
  use PDFium's default provider.

## Ink front buffer

- Present either the complete committed contour snapshot or the complete
  prediction snapshot, never a mixture. Each contour is a closed fill path;
  display, history, and export use the same native cubics.
- Each accepted move batch produces one committed frame and at most one
  replaceable prediction snapshot. A terminal batch produces the final frame
  and hands it off to history. Ordinary `onDraw` does not draw active ink.
- Prediction is presentation-only. Clear it before committed frames and on
  terminal input, cancellation, reset, document replacement, presenter loss,
  mode change, and disposal.
- Reject input without a presenter. Accept callbacks only for the current
  generation and sequence, and keep pending work bounded.
- A successful terminal input commits its stroke and clears transient contour
  state. A delayed acknowledgement for that same generation cannot restore
  cleared committed or prediction contours after the handoff.
- Page switches cancel active input and handoff, then rebuild display from
  that page's history. History is page-local; document dirty state is not.
