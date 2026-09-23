# iOS PDF export

`finalize()` exports committed content from the current working document to a
separate output. It does not modify the caller's source, the working document,
or page history. Live strokes, predictions, drafts, and selection are not
exported.

The original PDF pages remain PDF content in the output. Committed text is
written as PDF text where supported; PencilKit ink is composited as a raster
layer. Export preserves page order, geometry, and rotation, then validates the
result before publishing it. Publication is conditional on the finalize
operation remaining current.

Markup uses canonical page coordinates, independent of viewport zoom, pan, or
screen scale. Export behavior and errors are implemented in the native source;
this reference records the ownership and representation choices.
