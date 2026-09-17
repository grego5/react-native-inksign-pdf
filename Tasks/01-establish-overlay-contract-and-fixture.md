# 01 — Establish the overlay contract and deterministic fixture

[Back to plan index](../TASKS.md)

Status: Implemented; Android/iOS characterization pending on platform hosts

## Objective

Create a reviewable compatibility-text contract and a synthetic PDF fixture
that prove the platform APIs can recover Unicode and geometry from a Type-0,
`Identity-H`, non-embedded font before either platform presentation path is
changed.

## Non-goals

- Do not implement Android or iOS production rendering.
- Do not add a public prop, command, callback, or JavaScript data boundary.
- Do not detect whether a source font is embedded or whether the underlying
  PDF renderer actually drew a glyph.
- Do not use the user-provided business PDF as a committed test fixture.
- Do not alter export or add a replacement font asset.

## Read before editing

- `AGENTS.md` and `.agents/skills/inksign-pdf-docs/references/development.md`
  for repository workflow and validation policy.
- `.agents/skills/inksign-pdf-docs/references/architecture.md`, especially
  ownership, canonical coordinates, and export invariants.
- `android/src/main/java/com/margelo/nitro/inksignpdf/PdfSession.kt`:
  `PdfSession.open`, `PdfSessionResource`, and `PdfSessionInfo`.
- `ios/PdfView+Document.swift`: the `loadQueue` page-validation loop.
- `ios/DocumentState.swift`: `InkSignPdfPageState` ownership.
- Android S extension 18 documentation for `PdfPageTextObject.getText()`,
  `getMatrix()`, `getFontSize()`, `getFillColor()`, and `getRenderMode()`.
- PDFKit `PDFPage.attributedString`, `numberOfCharacters`,
  `characterBounds(at:)`, and `PDFSelection` line APIs.

## Current behavior and invariants

- Android opens and renders pages on one `PdfSessionWorker`; only page
  dimensions leave the worker during open.
- iOS loads `PDFDocument` and validates page geometry on `loadQueue`, then
  installs immutable page state on the main thread.
- The caller-owned PDF is read-only. Source text is currently rendered only by
  `PdfRendererPreV` or PDFKit.
- Canonical page coordinates are media-box-relative, top-left origin, positive
  Y down.
- `finalize()` must remain source-preserving and unaware of compatibility
  presentation.

## Implementation steps

1. Add `tools/testdata/pdf-font-overlay/generate-fixture.mjs` and generate a
   deterministic, uncompressed fixture at
   `tools/testdata/pdf-font-overlay/nonembedded-identity-text.pdf`.
   The generator must compute xref offsets rather than committing an invalid
   hand-edited PDF.
2. Give the fixture one small page with:
   - a visible vector border and baseline for coordinate assertions;
   - one Type-0 `Identity-H` font with no `/FontFile`, `/FontFile2`, or
     `/FontFile3`;
   - a complete `/ToUnicode` map for every used CID;
   - a mixed run containing ASCII digits/punctuation and non-ASCII Hebrew;
   - a second transformed run that exercises non-zero translation and font
     size without adding rotation until both platform APIs are characterized.
3. Add `tools/testdata/pdf-font-overlay/README.md` documenting the fixture's
   object structure, expected Unicode strings, page-space bounds, expected
   invisible source glyphs, and regeneration command. State that the Hebrew
   characters are test data for a general non-ASCII overlay policy, not a
   Hebrew-specific production branch.
4. Add a focused Android instrumentation characterization test that opens the
   fixture with `PdfRendererPreV`, obtains `PdfPageTextObject` entries, and
   records assertions for decoded Unicode, finite matrix values, font size,
   fill color, and render mode. Configure the fixture directory as an
   androidTest asset source rather than copying the PDF.
5. Add a focused iOS XCTest characterization that opens the same fixture with
   PDFKit and asserts the decoded page string/attributed string and finite
   character or line bounds. Add the shared fixture directory to the pod test
   specification resources.
6. If either platform fails to recover the expected Unicode, stop this plan's
   implementation at this task and record the observed API output. Do not
   invent a fallback parser in later tasks; revising the architecture would
   require a new approved plan.
7. Encode the v1 eligibility contract in platform-neutral test cases or
   mirrored platform tests:
   - U+0020 through U+007E and whitespace/control characters are never painted
     by the compatibility layer but retain layout advance;
   - a non-ASCII scalar is painted only when the platform default font reports
     a usable glyph;
   - a run with no paintable scalar is omitted;
   - malformed Unicode, non-finite geometry, non-positive font size, and
     unsupported render modes are omitted;
   - omission is a presentation result, not a PDF-open failure.

## Ownership, threading, lifecycle, coordinates, and API rules

- Characterization performs PDF inspection on the existing Android worker or
  iOS `loadQueue`; no PDF object may be retained by a UI-owned test seam.
- Test values crossing to UI/main ownership must be immutable scalars,
  strings, colors, and transforms.
- Keep original PDF-space observations in the characterization layer and
  explicitly document each conversion to canonical top-left page space.
- Add no public Nitro surface and do not run or edit Nitrogen output.
- The fixture may contain synthetic names and text only; do not reproduce
  customer identifiers or document content.

## Tests and expected observable results

- Regenerating the fixture produces byte-identical output.
- Android returns the expected Unicode string through
  `PdfPageTextObject.getText()` even though the source font is not embedded.
- iOS returns the expected Unicode string and finite page-space character or
  line bounds.
- The fixture still opens as one page with the expected media box in both
  platform readers.
- Eligibility tests keep ASCII transparent while selecting the non-ASCII
  characters in the mixed run.

## Validation

Run:

```powershell
node tools/testdata/pdf-font-overlay/generate-fixture.mjs --check
tools\test-android.ps1 -Mode connected
tools\test-ios-lifecycle.ps1
git diff --check -- ':!nitrogen/generated/**'
```

Run the iOS XCTest on macOS/Xcode. If unavailable, report it explicitly and do
not claim that PDFKit extraction was validated from the Windows source-contract
runner.

## Completion criteria

- The synthetic fixture is deterministic, documented, and consumed by both
  platform test targets.
- Both platform APIs demonstrably expose sufficient Unicode and finite
  placement data for this fixture.
- The eligibility and failure contracts are executable tests, not prose-only
  assumptions.
- No production rendering or export behavior changed.

## Proposed commit title

`test: characterize missing-font PDF text extraction`
