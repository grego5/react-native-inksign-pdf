# Missing-font PDF text fixture

This directory contains the deterministic PDF used by the Android and iOS
characterization tests for the display-only compatibility-text overlay.

Regenerate and check the exact bytes with:

```powershell
node tools/testdata/pdf-font-overlay/generate-fixture.mjs
node tools/testdata/pdf-font-overlay/generate-fixture.mjs --check
node tools/testdata/pdf-font-overlay/eligibility-contract.test.mjs
```

The fixture is one 240 x 160 point page. Its content stream draws a black
border at `[10, 10, 220, 140]` and a horizontal baseline from `(20, 40)` to
`(220, 40)` in the PDF's bottom-left coordinate system. The corresponding
canonical top-left coordinates are the same rectangle and a baseline at
`y = 120` because the page is 160 points high.

The page uses one Type-0 `/Identity-H` font. Its descendant is a Type-0
`/CIDFontType2` with a `/FontDescriptor` but deliberately has no `/FontFile`,
`/FontFile2`, or `/FontFile3`. Every used CID from `0001` through `000D` has a
`/ToUnicode` mapping:

| PDF run | Unicode text | PDF text matrix | Font size | Canonical baseline |
| --- | --- | --- | --- | --- |
| 1 | `2026: שלום` | `[1 0 0 1 24 96]` | 18 | `(24, 64)` |
| 2 | `A-7` | `[1 0 0 1 92 52]` | 12 | `(92, 108)` |

The matrices use PDF page coordinates; the canonical baseline converts the
translation with `canonicalY = pageHeight - pdfY`. With the fixture's 600-unit
default width, the first layout advance is 108 points and the second is 21.6
points. These are placement expectations, not renderer-specific glyph ink
boxes.

On Android S-extension 18, `PdfPageTextObject.getMatrix()` exposes the same
affine transform in Android `Matrix` order:
`[a, c, tx, b, d, ty, 0, 0, 1]`. The characterization test records that
nine-value platform result; the compatibility renderer converts it back to
the six PDF affine values before applying the canonical top-left transform.

The first run intentionally mixes ASCII digits, punctuation, whitespace, and
Hebrew. The second run adds a transformed placement and a different font size.
The Hebrew characters are test data for a general non-ASCII overlay policy,
not a Hebrew-specific production branch. ASCII U+0020 through U+007E,
whitespace, and controls retain layout advance but are never selected for
compatibility painting.

The eligibility contract also requires a usable default-font glyph for every
painted non-ASCII scalar. Runs with no paintable scalar, malformed Unicode,
non-finite geometry, non-positive font size, or unsupported text render mode
are omitted as presentation data; those conditions do not make the source PDF
fail to open.

The Android test consumes the PDF from its `androidTest` asset set and copies
the bytes to a temporary seekable file before opening `PdfRendererPreV`; it
does not rewrite the fixture. The iOS test consumes the same directory through
the pod test specification's resource bundle.
