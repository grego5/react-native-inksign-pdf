# 08 - Verify the PDFium backend checkpoint

[Plan](../TASKS.md)

Status: Test sources prepared; awaiting user execution
Complexity: High
Depends on: 01-07

## Objective and non-goals

Establish backend interoperability before ownership extraction. Tests/builds
remain deferred under the user restriction. This checkpoint concerns PDF reads,
assembly, text/font/ink export, and PDFKit display; it does not accept the final
headless architecture or claim to repair viewport/input defects.

## Read before editing

- Tasks 01-07 and their changed boundaries.
- `tools/test-ios-lifecycle.ps1`, `tools/test-ios-mac-vm.sh`, and maintainer
  `references/development.md`: source checks and authorized runner workflow.
- `ios/tests/PlacementRuleDetectorTests.swift`, `SignatureExportTests.swift`,
  `NativePDFBackendTests.swift`, and `MutablePageImageEncoderTests.swift`.
- `android/src/main/cpp/pdfium_session_smoke.cpp`: old shared exporter caller.
- Android `PdfiumSmokeInstrumentationTest` and `PdfExportContourTest`.

## Regression work

Use deterministic fixtures and existing builders. Cover mechanisms, not every
combination of options:

- Canonical analysis of an intrinsically rotated page with a nonzero media-box
  origin. Complete joined/reordered Hebrew labels retain usable dotted rules;
  partial labels and wrong repeated-word counts do not match. Preserve Android's
  existing snapshot orientation.
- Named/free value detection excludes the selected label and includes embedded
  values. Analysis comes from the actual working/candidate PDFium document.
- Mixed image/PDF creation and append/reorder/remove preserve page content,
  geometry, order, stable IDs, and image encoding policy. Failed/stale candidates
  do not publish.
- Exact CoreText system/fallback faces preserve multiline direction/alignment,
  wrapping, ligatures, combining sequences, and supplementary characters.
  Unsupported exact embedding fails explicitly rather than publishing wrong text.
- Committed PencilKit contours preserve vector geometry/color. Source content and
  visible source annotations survive; drafts/live strokes are excluded.
- Output applies rotation once, writes separately, and reopens through both
  PDFium and PDFKit. Extracted text and visible rendering must agree with intended
  content; metadata alone is insufficient.

Adapt new-module annotation-count/lock assertions to content assertions. Keep
source-annotation checks. Migrate the old `pdfium_session_smoke.cpp` writer caller,
then remove `PdfiumSignedDocumentExporter.*` and its CMake entry. Update obsolete
no-PDFium assertions without replacing behavior coverage with source predicates.

## Deferred execution and completion

After explicit authorization:

1. Hash-verify the Mac source, refresh Pods for changed linkage, and use
   `bash ./tools/test-ios-mac-vm.sh` with exact nonempty `IOS_TEST_ONLY` selectors.
   Verify simulator/device linkage, required symbols, and actual font feasibility.
2. Inspect finalized fixtures through independent PDFKit and external rendering.
   Use private sample PDFs only locally; check field resolution plus actual module
   insertion/export, not preservation alone. Remove temporary harnesses/assets.
3. Run the focused Android smoke/export classes using
   `tools/test-android.ps1 -Mode connected -Test <fully-qualified-class>`.
   Report unavailable devices as unverified.
4. Fix demonstrated backend defects before layering ownership changes. A deferred
   checkpoint may precede accepted static refactoring, but must remain explicitly
   unverified; do not invent a pass to advance the plan.

Run `git diff --check` now. Record artifact identity, exercised cases, real failures,
and unavailable gates. Keep final architecture/public documentation for Task 13.
Do not use slow-VM timing as a performance result. No tests/builds/Pod installation
are authorized by this file.

Proposed commit: `test(ios): establish PDFium backend interoperability checkpoint`.

## Prepared checks

- Analysis fixtures use the native PDFium snapshot, including intrinsic rotation
  and a nonzero MediaBox origin. Rule-scanning cases use the production backend.
- Image checks create PDFs through the native assembler. Assembly covers create,
  append, reorder, remove, source-byte preservation, boxes, and visible colors.
- Export checks use extracted embedded text and rendered contour bounds. Selected
  bounded lines are compared with committed CoreText rendering; source annotations
  remain checked. Unsupported ink keeps its explicit rejection case.
- The legacy shared exporter and PDFKit appearance type are removed; Android's
  smoke caller uses the common writer. Obsolete source predicates are removed.
- Whitespace checks pass. No tests, builds, or Pod installation were run.
- Backend acceptance still requires actual Apple-font embedding, clipped-form
  rendering, source preservation, and Android regression results. Supplementary
  glyph/combining-cluster feasibility remains part of the runtime checkpoint.

## User-run commands

From the Mac source directory, run each class with a separate result name:

```sh
IOS_POD_INSTALL=1 IOS_TEST_ONLY=SignatureExportTests \
  IOS_RESULT_NAME=pdfium-export bash tools/test-ios-mac-vm.sh

IOS_TEST_ONLY=PlacementRuleDetectorTests \
  IOS_RESULT_NAME=pdfium-analysis bash tools/test-ios-mac-vm.sh

IOS_TEST_ONLY=MutablePageImageEncoderTests \
  IOS_RESULT_NAME=pdfium-images bash tools/test-ios-mac-vm.sh

IOS_TEST_ONLY=NativePDFBackendTests \
  IOS_RESULT_NAME=pdfium-assembly bash tools/test-ios-mac-vm.sh
```

The first command refreshes changed native linkage; later calls reuse Pods when
the runner's manifest is unchanged. Return the first compiler/export error before
running broader suites. Tests use system-resolved fonts deliberately; embedding
failure is a backend finding, not a reason to skip the case.

On Windows with an Android device connected:

```powershell
.\tools\test-android.ps1 -Mode connected -Test com.margelo.nitro.inksignpdf.PdfiumSmokeInstrumentationTest
.\tools\test-android.ps1 -Mode connected -Test com.margelo.nitro.inksignpdf.PdfExportContourTest
```
