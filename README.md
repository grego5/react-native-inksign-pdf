# @grego5/react-native-inksign-pdf

- Sign PDF documents with ink and text annotations.
- Open PDFs or images from a file path or the native file picker.
- Add, remove, and reorder pages.
- Navigate pages, zoom, and undo or redo edits.
- Export the signed document as a new PDF.

Use the editor to add a signature or text, then export the document.

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

## Quick start

Open a PDF, draw a signature, place text, and save the result:

```tsx
import { useRef, useState } from 'react';
import { Button, Text, View } from 'react-native';
import {
  InkSignView,
  type InkSignViewHandle,
  type ViewerState,
} from '@grego5/react-native-inksign-pdf';

export function SigningView({ pdfPath, sessionId }: { pdfPath: string; sessionId: string }) {
  const pdf = useRef<InkSignViewHandle>(null);
  const [state, setState] = useState<ViewerState | null>(null);
  const [savedPath, setSavedPath] = useState('');

  async function savePdf() {
    const path = await pdf.current?.finalize();
    if (path) setSavedPath(path);
  }

  return (
    <View style={{ flex: 1 }}>
      <InkSignView
        key={sessionId}
        ref={pdf}
        initialDocument={pdfPath}
        onStateChange={(next) => {
          setState(next);
          if (next.error) console.error(next.error);
        }}
        style={{ flex: 1 }}
        strokeColor="#111827"
      />
      {state && state.pageIndex !== null && (
        <Text>
          Page {state.pageIndex + 1} of {state.pageCount}
        </Text>
      )}
      <Button title="Draw" onPress={() => pdf.current?.setMode('ink')} />
      <Button title="Place text" onPress={() => pdf.current?.setMode('text')} />
      <Button title="Undo" onPress={() => pdf.current?.undo()} />
      <Button title="Save PDF" onPress={() => void savePdf()} />
      {savedPath !== '' && <Text>Saved to {savedPath}</Text>}
    </View>
  );
}
```

Load a PDF or JPEG with `initialDocument` or call `open(path)` on the ref after
mounting. JPEG images become a single A4 page, scaled to fit without stretching.
Both accept a local path or `file://` URI. Choose **Draw** or **Place text** and
sign the page. `finalize()` returns a temporary PDF `file://` URI; copy the file
to persistent storage if you need it after closing the viewer.

## Methods

### Viewer ref

- `open(path, options?)` — Open a local PDF or JPEG path or `file://` URI.
  JPEG becomes one A4 page. Omitted viewport options fit the page.
- `close(cancelPending?)` — Close after earlier operations finish. Pass `true`
  to cancel pending work and close immediately.
- `addPages(options?)` — Import local PDFs or images; omit `sources` to open the
  native picker. Keeps the current page selected unless `activePage` is
  `'firstAdded'` or `'lastAdded'`.
  Android document loading and imports also accept `content://` and
  `android.resource://` URIs.
- `removePage()` — Remove the current page, keeping at least one page.
- `movePage(pageIndex)` — Reorder the current page to a zero-based index.
- `rotatePage(degrees)` — Rotate the current page clockwise by 90, 180, or 270
  degrees. Export preserves its orientation.
- `nextPage()` — Select the next page.
- `previousPage()` — Select the previous page.
- `getViewport()` — Read the current page's focus coordinates and zoom.
- `getPage(pageIndex?)` — Prepare a page for text operations; omission selects
  the current page. The returned page stays bound to that page after navigation
  or reordering, and becomes invalid when its page or document is removed.
- `setMode(mode, options?)` — Enter `'view'`, `'ink'`, or `'text'` synchronously
  once the document is ready. Preserves the viewport and returns a mode session.
  Options apply only to text mode; viewport changes wait for a placement tap.
  Switching modes finishes an open text entry or cancels untapped placement.
  `'view'` is a no-op when no document is open.
- `requestPageCoords()` — Wait for one page tap and return `{ pageId, pageIndex,
x, y }`, then return to view mode. Page or mode changes and teardown cancel
  the request. Use `setMode('view')` for Back.
- `getState()` — Read document identity, page count, and document-wide dirty state
  synchronously. An empty viewer reports null identity, zero pages, and clean state.
- `getSelectedText()` — Read the current native selection as a text handle, or
  `null`. Use it when executing actions; keep `onTextSelectionChange` for button
  availability.
- `undo()` — Undo the last edit on the current page.
- `redo()` — Redo an undone edit on the current page.
- `clear()` — Remove editable ink and module text from the current page as one
  undoable edit. Original PDF content is preserved.
- `clearInk()` — Remove only editable ink from the current page as one undoable edit.
- `setTextDirection(direction)` — Set the base text direction: `'ltr'`, `'rtl'`,
  or `'auto'` to follow app direction.
- `finalize()` — Export to a temporary PDF `file://` URI. Copy it to persistent
  storage before closing the viewer if you need to retain it. On iOS, original
  PDF text may lose search/copy support after export.

### Prepared page

Prepare once with `getPage()`; text resolution and value operations are synchronous.

- `getState()` — Read stable page identity, current index/count, displayed
  width/height, clockwise rotation (`0`, `90`, `180`, `270`), `hasInk`, `hasText`,
  page-content `isDirty`, `canUndo`, and `canRedo`.
  Does not switch pages or scan the PDF. Content flags exclude live drafts and
  imported PDF content, including signatures in reopened InkSign exports.
  Dirty/history fields read stack metadata; content flags inspect committed
  session content in memory.

Page dimensions and text bounds use displayed PDF points (1/72 inch), with the
origin at the rotated page's top-left, x increasing rightward and y downward.
New text uses that orientation; existing text retains its captured layout when
the page rotates. A 320 × 240 page rotated 90° reports 240 × 320.

- `resolveText(options)` — Resolve a complete printed field name or free
  `bounds: { x, y, width, height }` to a numeric ID. Scanned labels need a text layer.
- `getTextValue(id)` — Read entered text, falling back to embedded PDF text or `''`.
- `setTextValue(id, text, options?)` — Atomically write module text and optional formatting on Android. Pass `''` to remove it and reveal
  any embedded value. Viewer commits are tracked by default; headless commits
  are untracked.
- `setTextOptions(id, options)` — Update formatting; omitted options retain their values.
- `adjustTextSize(id, delta)` — Increase or decrease font size by page points;
  return the resulting size.
- `getTextEntry(id)` — Read the value, value source, and target metadata.
- `getTextEntries()` — Read all resolved text targets on the page.
- `focusText(id, options?)` — Focus a resolved target without changing mode.
  Options are `zoom`, `verticalAnchor` (`'top'`, `'bottom'`, or `'center'`), and
  `edgeOffset` in page points. Defaults to zoom 2 and center.

On Android, pass `untracked: true` to a programmatic text mutation to update the
permanent base outside undo/redo history:

```ts
page.setTextValue(id, report.number, { untracked: true });
```

The option defaults to `false` and applies only to that call. Base edits leave
dirty state unchanged, survive undo/redo, and preserve unrelated history. If that
text ID has tracked edits in current content or retained undo/redo, the flag is
ignored and the edit records normally. Headless documents retain all edits without
undo history or content dirty state. iOS does not support `untracked: true`.

### Mode session

Use the session returned by `setMode()` when a workflow awaits page preparation
or a user tap before focusing. If the user switches modes while it waits, the
session and its pages reject with `operation_cancelled`, preventing a delayed
focus or write from taking over the new interaction. Catch cancellation once
around the workflow with `isOperationCancelled(error)`.

Sessions are optional. Use ordinary `view.getPage()` for text operations that
should remain available across mode changes. Both kinds of handles become
invalid when their document closes.

- `session.getPage(pageIndex?)` — Prepare a page whose operations belong to this
  mode session.
- `session.requestPageCoords()` — Pick one point and return to the session's
  mode. Page changes cancel the picker.
- `session.setViewport(options?)` — Zoom or focus without changing mode. Pass
  `{}` to fit; omit options to preserve the viewport.

### Selected text handle

The handle binds its page and text ID. Selection/navigation changes do not
retarget it; document closure, page deletion, or target invalidation rejects
operations.

- `getValue()` — Read the current value.
- `setValue(text, options?)` — Update text and optional formatting on Android; `''` removes module text.
- `setOptions(options)` — Update formatting.
- `adjustSize(delta)` — Adjust font size by page points and return the result.

### Android debug recording

Available in Android debug builds:

- `startDebugRecording()` — Clear the bounded trace and start recording.
- `stopDebugRecording()` — Stop recording.
- `exportDebugRecording()` — Export the stopped trace as replayable CSV.

## Events and paging

- `onStateChange` — Document identity/count/dirty state, active `pageIndex`, viewer
  mode, and load error. `pageIndex` is zero-based and `null` without a document;
  combine it with `pageCount` from this event for a page counter.
- `onPageChange` — Active `pageId`, `width`, `height`, `rotation`, `canUndo`, and
  `canRedo`. Read content flags (`hasInk`, `hasText`), page `isDirty`, and that
  page's current index/count through page `getState()`.

Both events suppress unchanged payloads. An edit need not emit
an event. Viewer/document `getState()` returns global `documentId`, `pageCount`,
and `isDirty`; active index, mode, and error are available in `onStateChange`.
Page dirty state equals `canUndo`: undoing all tracked edits makes it clean, even
with redo entries or untracked content remaining. Document dirty state also includes
structural changes. Export leaves history and dirty state unchanged.
  Identical snapshots are deduplicated.
- `onTextSelectionChange` — Selected text ID and page ID, or `null`.
- `onZoomChange` — Settled zoom relative to page fit: `1` is fitted, above `1`
  is zoomed in, below `1` is zoomed out.
- `pagerDirection="rtl"` — Right-to-left paging; omission follows app direction.

See the [public API](./src/InkSignView.nitro.ts) for all props and options.

## Examples

### Update selected text

```ts
const text = pdf.current?.getSelectedText();
text?.setOptions({ alignment: 'center' });
// Remove module text:
text?.setValue('');
```

### Pick a signing location

```ts
import { isOperationCancelled } from '@grego5/react-native-inksign-pdf';

try {
  const session = view.setMode('ink');
  const target = await session.requestPageCoords();
  await session.setViewport({ zoom: 3, x: target.x, y: target.y });
} catch (error) {
  if (!isOperationCancelled(error)) throw error;
}
```

### Add image pages

```ts
await pdf.current?.addPages({
  sources: [imagePath],
  imagePageSize: { width: 420, height: 594 },
  activePage: 'lastAdded',
});
```

### Fill an empty field

```ts
const page = await pdf.current?.getPage();
if (page) {
  const id = page.resolveText({ fieldName: 'Name' });
  if (!page.getTextValue(id)) page.setTextValue(id, 'Ada Lovelace');
}
```

### Configure an Android fallback font

Pass one source URI: HTTP(S), a local file, Android content/resource URI, or an
Expo packaged asset. Android keeps the font in memory for the document session.

```tsx
<InkSignView androidFallbackFont={{ uri: fontUri }} />
```


### Headless documents and named fonts (Android)

`openDoc(uri, options?)` opens a PDF or image without mounting a view. It exposes
`pageCount`, `getPage(index)`, `addPages({ sources })`, `removePage(index)`,
`movePage(fromIndex, toIndex)`, and `rotatePage(index, 90 | 180 | 270)`.
`document.getState()` returns document-wide metadata. `page.getState()` and the
prepared-page text methods work without focus, using the same geometry and
session-content contracts as viewer page handles. Headless pages retain content
without recording undo actions or making page content dirty. Document dirty state
still reflects structural edits such as adding, removing, moving, or rotating pages.
`finalize()` creates a new PDF using the existing export pipeline; source files
remain unchanged. Visible signatures and supported source annotations follow the
same preservation rules as viewer export; cryptographic signature validity is
outside the editing contract. Returned files are caller-owned and survive close.
`close()` immediately rejects new commands and reads, including `pageCount` and
`getState()`. It is terminal, idempotent, and resolves after admitted work and native
resource cleanup complete. Retained page handles reject edits after close.

```ts
import { openDoc } from '@grego5/react-native-inksign-pdf';

const document = await openDoc(file.uri);
try {
  await document.loadFonts([{ name: 'template', uri: bundledFontUri }]);
  const page = await document.getPage(0);
  const id = page.resolveText({ bounds: template.reportNumberBounds });
  page.setTextValue(id, report.number, {
    font: 'template', alignment: 'center', maxLines: 1,
  });
  const outputUri = await document.finalize();
} finally {
  await document.close();
}
```

The viewer exposes the same `loadFonts([{ name, uri }])` method and named `font`
option in text resolution, insertion, and formatting. Font names are exact and
case-sensitive. Omit `font` to retain the current selection; use `font: null` to
restore the system font. Alignment uses the target rectangle, which the template
owns, rather than the whole page.

Named fonts accept local files, Android content/resource URIs, and Expo bundled
asset URIs. Static single-face TrueType outlines are supported; collections,
variable fonts, CFF outlines, and restricted embedding reject. Missing glyphs do
not reject text input. Android uses system fallback in the editor and in API 31+
PDF export. On API 24–30, named-font export uses the selected font's missing-glyph
appearance because system fallback font resources are unavailable to this path.
Each document/view caches a source once and shares it between names. Resources
remain available through export and are released on document close or view
teardown. Caller font files remain unchanged. Headless documents and named fonts
are currently Android-only; iOS retains its existing PDFKit implementation.
Headless automatic text direction follows the React Native app direction.
