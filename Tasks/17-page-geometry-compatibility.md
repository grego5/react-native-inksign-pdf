# Task 17 — Review and align imported-page geometry compatibility

Status: Implemented; iOS focused validation passed; Android/device validation pending.

## Goal

Review Android and iOS imported-page handling and choose the shared contract
with the strongest practical PDF compatibility and simplest ownership. Existing
platform behavior may change when justified by that review. Neither Android nor
iOS is authoritative for API behavior. Gaps discovered on either platform inform
the shared contract, and both implementations must align with the final decision.

## Work

- Trace MediaBox, CropBox, nonzero origins, intrinsic rotation, and session
  rotation through analysis, rendering, text targets, taps, focus, and export.
- Compare Android PDFium and iOS PDFKit presentation with the authoritative
  PDFium document geometry. Identify deliberate conversions and inconsistencies.
- Choose and document canonical document coordinates, visible page boundaries,
  public dimensions/bounds, and viewer-boundary conversions. Keep one owner for
  geometry and derived transforms; avoid platform-specific copies of state.
- Align both platforms with the selected contract. Preserve imported geometry
  and content; fitting, zooming, and scrolling are presentation operations.
  Image-to-page sizing remains a separate creation policy.
- Rewrite affected API/reference contracts in place. Explain any public behavior
  changes concisely; omit migration history from maintainer references.

## Verification

Use deterministic PDF fixtures with offset MediaBox/CropBox and quarter-turn
rotations. Verify both platforms identify the same visible field and rule,
place text at the requested physical location, focus that location, and preserve
visible content after export/reopen. Include an ordinary uncropped page as a
regression baseline. Compile affected native boundaries and run focused geometry
checks through the authorized validation workflow. Record device presentation
checks separately from slow-VM correctness results.

Current Android crop-coordinate validation remains pending; this task does not
claim it passed or authorize additional test execution.

## Selected contract and implementation

- Imported PDF boxes remain intact. The visible page is CropBox intersected with
  MediaBox; omitted CropBox follows MediaBox. Page dimensions, taps, focus, and
  public bounds use that visible page after rotation. Fit/zoom do not rewrite boxes.
- Shared source analysis retains MediaBox coordinates internally. Both native
  bridges use one shared visible-page projection for exposed analysis and rules.
  Stored/editable content uses unrotated visible-box-relative top-left coordinates;
  captured layout rotation remains separate.
- Swift geometry retains both original MediaBox and visible bounds. PDFKit displays
  CropBox; core layout, overlay conversion, and viewport use visible bounds.
- Shared export uses visible dimensions and PDF origin on both platforms; the
  platform-specific MediaBox sizing flag is removed. Assembly checks preserve
  visible bounds as well as MediaBox and rotation.
- Added iOS cropped-analysis and cropped-insertion/export cases through all quarter
  turns. Existing Android crop fixture checks the shared analysis conversion.
  Native compilation, Android export/device checks, and iOS focused runtime checks
  are pending; no tests or builds ran in the implementation chat.

## Recorded validation

Hash-verified Mac simulator runs passed DocumentCoreTests 6/6, PlacementRuleDetectorTests 17/17, and SignatureExportTests 3/3. Cropped analysis and insertion/export through quarter turns passed. Export fixture geometry and raster comparison use its declared visible box; original PDF box/source-content preservation assertions remain. Android native compilation, crop analysis/export checks, and physical-device presentation remain unverified. No completion claim is made for those gates.
