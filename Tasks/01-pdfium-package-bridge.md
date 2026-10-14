# 01 - Package PDFium and establish the bridge

[Plan](../TASKS.md)

Status: Complete (iOS implementation and applicable simulator checks)
Complexity: Medium
Depends on: none

## Objective and non-goals

Make the published Apple static SDK available to the pod and expose a narrow
Objective-C++ worker adapter. Later tasks replace individual backends. Do not
rebuild SDKs or change Nitro interfaces.

## Read before editing

- `ReactNativeInkSignPdf.podspec`: sources, linkage, generated autolinking.
- `package.json`: published files; `.gitignore`: build output exclusions.
- `core/third_party/pdfium/manifest.json`: pinned release metadata.
- `core/pdfium-adapter/PdfiumDocumentSession.hpp` and
  `PdfiumLibraryInternal.hpp`: session ownership and shared locking.
- `ios/InkSignDocumentState.swift`: `InkSignPdfDocumentCoordinator.pdfQueue`.
- Maintainer `references/development.md` and `swift-ios/view-lifecycle.md`.

## Current contract

The pod currently links no PDFium. One serial PDF queue runs document work.
Shared PDFium sessions own input bytes and handles; callers serialize access
and destruction. Keep that worker and process-level library lifetime.

## Implementation

1. Add Apple metadata alongside Android metadata: archive
   `PDFium-static-157.0.8086.0.xcframework.tar.gz`, SHA-256
   `0eb0043326416d27222a1edf31b60c7e05dea34657c766b701ead977ef0e04f4`,
   size `346727156`, from release `pdfium-157.0.8086.0-static`.
2. Add `tools/fetch-pdfium-apple.rb`, invoked by the podspec for local path pods
   as well as fetched pods. Do not rely solely on `prepare_command`, which does
   not cover local path installation. Cache under `ios/build/pdfium`; verify
   archive hash before extraction and publish the SDK atomically. Valid cached
   content avoids a repeated download; an incomplete extraction is never accepted.
3. Declare the static XCFramework as vendored and list shared C++ adapter sources
   explicitly. Preserve C++20, libc++, and Nitro autolinking. Use matching headers
   and let Xcode select the device/simulator slice.
4. Add `ios/PdfiumBackend.h` and `.mm`. Expose owned metadata and analysis
   inputs/results through Foundation value objects. Translate failures to NSError
   and the existing Swift error boundary; FPDF pointers stay internal.
5. Each bridge call owns a temporary session and closes it before returning.
   Invoke it on `pdfQueue` using the shared library lease/lock. Task 09 may retain
   backend resources under the extracted core; do not add a second logical
   document store or independently initialized PDFium runtime.
6. Include the fetcher and required C++/license files in the npm file list. Keep
   SDK downloads out of the package and Git. Use no VM addresses, signing data,
   or Mac checkout paths in product packaging.

## Static validation and completion

- Trace download failure, cache recovery, destruction, and error conversion.
- Inspect package and pod source paths, including the example's local dependency.
- Run `git diff --check`; iOS linkage and applicable runtime gates passed in Task 08.
- Proposed commit: `build(ios): consume pinned PDFium static SDK`.

## Implementation result

- Pod evaluation prepares a checksummed cached SDK for local and fetched pods.
  The pod links the static XCFramework and selected shared adapters; C++ headers
  remain private to avoid importing them into Swift's Objective-C module.
- The bridge returns owned metadata, canonical glyph/row/rule snapshots, and
  NSError failures; all session resources are scoped to the synchronous call.
- The fetcher is included in published package files. No tests/builds/Pod
  installation, Apple linkage, and focused runtime acceptance passed.
