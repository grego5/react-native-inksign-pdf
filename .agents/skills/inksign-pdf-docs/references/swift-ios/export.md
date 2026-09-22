# iOS PDF export

`finalize()` exports the committed markup without changing the source PDF or
the page history.

## Export flow

1. The coordinator admits one finalize operation and captures the current
   working source URL, ordered page geometry, committed PencilKit drawings,
   committed text annotations, and operation generation. After a structural
   page mutation, this source is the newly assembled PDF in its published page
   order. The active or uncommitted interaction is not included.
2. On the export queue, copy the captured source into a unique immutable
   snapshot artifact, then create a new PDF and process each source page in
   order.
3. Copy the source page into the new PDF with `CGContext.drawPDFPage`. The
   original page content is therefore retained; the page is not flattened into
   one image.
4. Add the committed markup using the rules below.
5. Reopen the result, verify page count, page order, media boxes, and rotations,
then atomically publish the verified file in the native cache directory while
the coordinator still owns the current operation and generation.

## What remains vector

- The original PDF content is copied as PDF content, so its existing text and
  vector graphics remain available in the exported document.
- Committed text annotations are drawn directly into the PDF context with Core
  Text. This is the vector/selectable text path.
- If Core Text cannot construct a required line, only that text layer falls
  back to a transparent raster layer at the canonical export resolution. The
  source page is still not flattened.

PencilKit ink is not converted to PDF vector paths on iOS. The committed
drawing is rendered to a transparent image at two pixels per canonical page
unit and composited over the copied source page. Thus an export containing ink
has vector-preserving source content plus a raster ink overlay.

## Coordinates and safety

Markup is stored in canonical page coordinates with a top-left origin. Export
applies the media-box transform when drawing into the PDF; viewport zoom, pan,
screen scale, and the temporary text editor do not affect placement or physical
size.

Export is non-consuming and uses unique cache files. The source and output must
be different paths. Conflicting open or finalize operations are rejected.
Capture, writing, verification, publication, cancellation, and cleanup failures
are reported as `invalid_output_path`,
`pdf_export_failed`, or `operation_cancelled` as appropriate.
