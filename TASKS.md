# Shared PDFium compatibility-text geometry

Replace the Android selection and iOS PDFKit compatibility-text geometry
heuristics with one lazy shared C++20 extractor backed by a pinned PDFium
revision. Native platform renderers continue to draw the source PDF, while
Android Canvas and iOS Core Text draw only replacement glyph clusters from
immutable positioned-character snapshots.

Compatibility text remains presentation-only. It never enters history, dirty
state, callbacks, the public Nitro API, or finalized PDFs.

## Constraints

- Keep `PdfRendererPreV` on Android and PDFKit/Core Graphics on iOS as the base
  page renderers.
- Keep all PDFium handles inside a thread-confined shared native session.
- Extract pages lazily on the existing serial PDF workers and retain only a
  bounded immutable page cache.
- Normalize origins, bounds, vectors, and matrices into the repository's
  media-box-relative, top-left, Y-down canonical coordinates.
- Shape replacement clusters with platform fonts without paragraph relayout.
- Retain current platform heuristic providers only during migration; stop
  extending their geometry logic.
- Prefer focused structural tests and real-device visual acceptance; do not add
  pixel-perfect screenshot tests.

## Task order

1. [Pin and package PDFium for Android and iOS](Tasks/01-package-pdfium.md)
2. [Create the shared PDFium document session and positioned-text model](Tasks/02-shared-pdfium-session-and-model.md)
3. [Extract canonical character geometry and bounded diagnostics](Tasks/03-canonical-text-extraction.md)
4. [Connect lazy shared geometry to the Android PDF session](Tasks/04-android-pdfium-geometry-bridge.md)
5. [Render positioned replacement clusters on Android](Tasks/05-android-positioned-cluster-rendering.md)
6. [Connect lazy shared geometry to the iOS document lifecycle](Tasks/06-ios-pdfium-geometry-bridge.md)
7. [Render positioned replacement clusters on iOS](Tasks/07-ios-positioned-cluster-rendering.md)
8. [Retire heuristic providers and complete device acceptance](Tasks/08-retire-heuristics-and-validate.md)
