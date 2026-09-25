# @grego5/react-native-inksign-pdf

- PDF document signing with ink in a React Native module.
- Load document or images programatically by path, or through native file picker. Images converted to pdf pages automatically.
- Add additional files to be added as pages. Can add/remove/reorder pages.
- Can bring own scanner module and bridge it seamlessly by adding pages through path to the file in cacae directory.
- Displays loaded PDF as background. Including swipe/method pagination.
- Uses PDFium on Android for document loading, rendering, page assembly, and export; iOS uses PDFKit, Quartz, and CoreText for PDF operations.
- Android's optional `fallbackFont` applies to source-PDF rendering.
- Supports velocity-driven ink, text annotations, and history.
- Android using custom c++ InkEngine, integrating Google Ink line modeling algorithms, and low-latency front buffer api for zero lag drawing before committing to standard render node. For some reason uncommon technique in most apps.
- iOS uses PDFKit for PDF operations and page presentation, CoreText for text, and PencilKit for ink input. No web support.
- Exports a new PDF that retains visible source pages and adds text and signatures as locked annotations with vector appearances.

Intended workflow: open pdf, double click an area or dedicated button to enter edit mode, zoom into tapped area or prefined coordinates,
draw a signature, save to new file. The brush doesn't scale with zoom level, but the drawn shape does.

![Screenshot 1](example/screenshot.jpg)

## Requirements

- Node.js 20
- Android 7.0/API 24 or newer
- iOS 16.0
- A native iOS or Android project

## Installation

```sh
npm install git+https://github.com/grego5/react-native-inksign-pdf.git
```

For iOS:

```sh
npx pod-install
```

The module requires a native React Native build; it is not supported in Expo
Go.

### Android native artifacts

Android builds use the pinned release record in
`android/ink-engine-release.json`. Gradle downloads and verifies the single
InkEngine archive during the native build, then caches its ABI libraries under
the Gradle `build` directory. The npm package does not contain InkEngine
static libraries or the Google Ink/Abseil source trees. A previously verified
cache can be reused offline; a missing or invalid cache requires access to the
pinned GitHub Release.

Repository developers can deliberately compile the checked-out sources with
`-PReactNativeInkSignPdf_useSourceInkEngine=true`. Normal consumer builds do
not select source mode automatically.

## Quick start

```tsx
import { useRef, useState } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';
import {
  InkSignView,
  type PageInfo,
  type TextDirection,
  type InkSignViewHandle,
  type StateChangeEvent,
} from '@grego5/react-native-inksign-pdf';

export function SigningView({ pdfPath }: { pdfPath: string }) {
  const pdf = useRef<InkSignViewHandle>(null);
  const [page, setPage] = useState<PageInfo | null>(null);
  const [state, setState] = useState<StateChangeEvent>({
    canUndo: false,
    canRedo: false,
    isDirty: false,
    mode: 'view',
  });
  const [status, setStatus] = useState('Choose a PDF to begin');
  const [textDirection, setTextDirection] = useState<TextDirection>('auto');

  async function openPdf() {
    try {
      const info = await pdf.current!.open(pdfPath);
      setPage(info);
      setStatus('Ready to sign');
    } catch {
      setStatus('Unable to open PDF');
    }
  }

  async function savePdf() {
    try {
      const outputPath = await pdf.current!.finalize();
      setStatus(`Signed PDF: ${outputPath}`);
    } catch {
      setStatus('Unable to export PDF');
    }
  }

  return (
    <View style={styles.screen}>
      <InkSignView
        ref={pdf}
        style={styles.pdf}
        strokeColor="#111111"
        strokeMinWidth={2}
        strokeMaxWidth={4}
        onStateChange={setState}
        onPageChange={setPage}
      />

      <Text style={styles.status}>
        {page ? `Page ${page.pageIndex + 1} of ${page.pageCount}` : status}
        {page ? ` · ${state.mode}${state.isDirty ? ' · unsaved' : ''}` : ''}
      </Text>

      <View style={styles.toolbar}>
        <Button title="Open PDF" onPress={() => void openPdf()} />
        <Button
          title="Previous"
          disabled={!page || page.pageIndex === 0}
          onPress={() => {
            try {
              pdf.current?.previousPage();
            } catch (error) {
              console.warn('Page change failed', error);
            }
          }}
        />
        <Button
          title="Next"
          disabled={!page || page.pageIndex === page.pageCount - 1}
          onPress={() => {
            try {
              pdf.current?.nextPage();
            } catch (error) {
              console.warn('Page change failed', error);
            }
          }}
        />
        <Button
          title="Draw"
          disabled={!page}
          onPress={() => {
            try {
              pdf.current?.enterEditMode();
            } catch (error) {
              console.warn('Mode change failed', error);
            }
          }}
        />
        <Button
          title="View"
          disabled={!page}
          onPress={() => {
            try {
              pdf.current?.enterViewMode();
            } catch (error) {
              console.warn('Mode change failed', error);
            }
          }}
        />
        <Button
          title="Place text"
          disabled={!page}
          onPress={() => {
            try {
              pdf.current?.setTextDirection(textDirection);
              pdf.current?.insertAnnotationOn();
            } catch (error) {
              console.warn('Text placement failed', error);
            }
          }}
        />
        <Button
          title={`Text direction: ${textDirection.toUpperCase()}`}
          onPress={() => {
            setTextDirection((current) =>
              current === 'auto' ? 'ltr' : current === 'ltr' ? 'rtl' : 'auto',
            );
          }}
        />
        <Button title="Undo" disabled={!state.canUndo} onPress={() => pdf.current?.undo()} />
        <Button title="Redo" disabled={!state.canRedo} onPress={() => pdf.current?.redo()} />
        <Button title="Clear" disabled={!state.isDirty} onPress={() => pdf.current?.clear()} />
        <Button
          title="Save signed PDF"
          disabled={!page || !state.isDirty}
          onPress={() => void savePdf()}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1 },
  pdf: { flex: 1 },
  status: { padding: 8, textAlign: 'center' },
  toolbar: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    justifyContent: 'center',
    padding: 8,
  },
});
```

`open()` accepts a caller-owned local PDF path and starts in view mode. Keep the
source file readable while the view is mounted. The `fallbackFont` component prop
provides an optional local font for Android PDFium substitution. It is captured
when `open()` or `addPages()` runs, so changing it takes effect on the next such
operation. iOS uses CoreText and the system font fallback behavior. `finalize()`
returns the path to the signed PDF; copy that file to durable application
storage before unmounting the view. Native temporary artifacts are kept below
the app cache directory; iOS can override its leaf directory with the
`ReactNativeInkSignPdfCacheDirectoryName` Info.plist key, and Android with the
`com.margelo.nitro.inksignpdf.CACHE_DIRECTORY_NAME` application metadata key.

## Component API

### Props

- `fallbackFont` — one optional Android PDFium fallback font resource; changes take effect on the next `open()` or `addPages()`.
- `strokeColor` — ink color as `#RRGGBB`.
- `strokeMinWidth`, `strokeMaxWidth` — ink width range.
- `strokeSmoothing` — Android input smoothing from `0` to `1`.
- `defaultTextFontSize` — font size for new text annotations.
- `defaultTextColor` — color saved with new text annotations.
- `outlineColor`, `selectedOutlineColor` — text outline colors.
- `editorBackgroundColor`, `selectedBackgroundColor` — text UI colors.
- `doubleTap` — `{ zoom, enterEditMode? }` double-tap behavior.
- `keyboardAvoidanceEnabled` — keep the text editor above the keyboard.
- `onStateChange` — coarse interaction and history state.
- `onPageChange` — notification after a real page switch.

Example color configuration:

```tsx
<InkSignView
  strokeColor="#111827"
  defaultTextColor="#0F172A"
  outlineColor="#64748B"
  selectedOutlineColor="#2563EB"
  editorBackgroundColor="#FFFFFF"
  selectedBackgroundColor="#DBEAFE"
/>
```

Colors use opaque `#RRGGBB` strings. `defaultTextColor` is saved with new
annotations; the other text colors control presentation.

### Ref methods

```ts
open(path, options?)
addPages(options?)
removePage()
movePage(pageIndex)
nextPage()
previousPage()
getViewport()
enterEditMode(viewport?)
enterViewMode(viewport?)
undo()
redo()
clear()
setTextDirection(direction)
insertAnnotationOn()
insertAnnotationOff()
increaseTextSize()
decreaseTextSize()
removeTextAnnotation()
finalize()
```

`open(path)` explicitly replaces the current PDF and returns its page metadata.
If replacement fails, the current document remains open. Use `addPages()` for
the native picker: with no document it creates one; otherwise it appends pages.
The picker accepts PDFs and images by default, expands every selected PDF in
page order, and creates one page per image. `type: 'pdf'` or `type: 'image'`
restricts the picker. Selection order is retained.

`imagePageSize` supplies image-page width and height in PDF points and applies
to every selected image. Without it, images use the active page size when one
exists, or portrait A4 (595.28 × 841.89 points) when creating a document.
Pass `sources` to import ordered local paths or file URLs without showing a
picker; this is intended for files produced by a scanner or another native
flow.

```ts
const result = await pdf.current?.addPages({
  type: 'image',
  imagePageSize: { width: 420, height: 594 },
});
// { addedPageCount: number, pageInfo?: PageInfo }
```

Picker cancellation and an empty `sources` list leave the document unchanged
and resolve with `addedPageCount: 0`. `pageInfo` describes the unchanged active
page when a document exists and is omitted when no document exists. After pages
are added, the first new page becomes active. `removePage()` removes and
returns metadata for the current page; it rejects removal of the final page.
`movePage(pageIndex)` moves the current page to a zero-based destination
position, shifting intervening pages rather than swapping them. Moving to its
current index is a no-op. Ink and text remain attached to their page when it
moves.

Open, add, remove, move, and finalize share one serialized document-operation
boundary. A conflicting operation rejects with `operation_in_progress`.
Page navigation is synchronous to initiate and publishes the committed result
through `onPageChange`:

```ts
{
  (pageIndex, pageCount, width, height);
}
```

`getViewport()` returns a viewport snapshot synchronously and throws when the
view is not ready. Synchronous commands throw validation errors directly.

Page indexes are zero-based. Viewport values use canonical PDF page
coordinates:

```ts
{
  (x, y, zoom);
}
```

Pass paired `x` and `y` to focus a page point. Pass `zoom` for an absolute
zoom level. An empty viewport object fits and centers the page; omitting the
argument preserves the current viewport where applicable.

## Interaction model

- View mode provides pan, pinch zoom, and page navigation.
- Edit mode accepts finger or stylus input for velocity-driven ink. The
  viewport stays fixed while drawing; text editing may pan at the current zoom.
- `insertAnnotationOn()` arms one text placement; the next page tap opens the
  native text editor. The tap places the initial caret at the content edge
  (left for LTR, right for RTL); a new empty box starts at one em wide and
  stays inside the page. Idle and selected outlines share the editor's padded
  frame, while saved text bounds exclude that presentation padding.
- `setTextDirection('ltr' | 'rtl' | 'auto')` controls the base direction for
  new text annotations. The React app owns the direction selector and should
  call this method before placement or while placement is pending. Explicit
  directions are fixed. On iOS, `auto` follows the keyboard language when UIKit
  reports one while a new editor is empty. It locks on first content and follows
  again if erased. Committed annotations keep their saved direction. On Android,
  `auto` uses the keyboard language when available, then the app's visible
  default direction. Android resamples `auto` while the draft is empty; the
  first inserted text fixes its direction through keyboard changes and mixed
  scripts. Erasing the whole draft makes `auto` eligible to resample. IME
  language reporting is best effort. RTL anchors the right edge and LTR anchors
  the left.
- On iOS, the placement tap anchors the first caret edge. Text selection and
  movement apply to text hit areas; other edit-mode touches remain available to
  PencilKit. Editing keeps the current zoom and pans to keep the text outline and
  caret visible with a 24-point margin when the keyboard-adjusted viewport allows.
- Text, ink, undo, redo, and clear are managed by the native view.
- `onStateChange` reports `canUndo`, `canRedo`, `isDirty`, and one of
  `view`, `draw`, `textPlacement`, `textSelected`, or `textEditing`.
- The application owns its toolbar and any saved viewport bookmarks.

## Export

```tsx
const signedPath = await pdf.current?.finalize();
```

The source PDF is preserved. The returned file contains the committed ink and
text annotations and is written to native temporary storage. Copy it to the
application's durable destination when it must outlive the signing view.

## Further documentation

- [Public API spec](./src/InkSignView.nitro.ts)
- [Architecture and invariants](./.agents/skills/inksign-pdf-docs/references/architecture.md)
- [Android input and viewport behavior](./.agents/skills/inksign-pdf-docs/references/android/viewport-input.md)
- [iOS input and viewport behavior](./.agents/skills/inksign-pdf-docs/references/swift-ios/viewport-input.md)
