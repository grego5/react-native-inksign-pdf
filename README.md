# @grego5/react-native-inksign-pdf

- Sign PDF documents with ink and text annotations.
- Open PDFs or images from a file path or the native file picker.
- Add, remove, rotate, and reorder pages.
- Navigate pages, zoom, and undo or redo edits.
- Imperative page editing through headless utility or viewer instance ref.
- Zoom focus page programatically into lines near searchable text, page coordinates, or request user tap.
- Export the signed document as a new PDF.

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

The receiver determines which API you use:

| Handle | Obtain it with | Used for |
| --- | --- | --- |
| `view` | `ref.current` | Viewer navigation and interaction |
| `document` | `await openDoc(uri)` | Headless document editing on Android |
| `page` | `await view.getPage()`, `await document.getPage(0)`, or `await session.getPage()` | Page inspection and text edits |
| `session` | `view.setMode(...)` | A workflow tied to the current mode |
| `text` | `view.getSelectedText()` | Editing the selected text item |

### Viewer ref

- `view.loadFonts(fonts)` — Preload named fonts on Android.
- `view.open(path, options?)` — Open a local PDF or JPEG path or `file://` URI.
  JPEG becomes one A4 page. Omitted viewport options fit the page.
- `view.close(cancelPending?)` — Close after earlier operations finish. Pass `true`
  to cancel pending work and close immediately.
- `view.addPages(options?)` — Import local PDFs or images; omit `sources` to open the
  native picker. Keeps the current page selected unless `activePage` is
  `'firstAdded'` or `'lastAdded'`.
  Android document loading and imports also accept `content://` and
  `android.resource://` URIs.
- `view.removePage()` — Remove the current page, keeping at least one page.
- `view.movePage(pageIndex)` — Reorder the current page to a zero-based index.
- `view.rotatePage(degrees)` — Rotate the current page clockwise by 90, 180, or 270
  degrees. Export preserves its orientation.
- `view.nextPage()` — Select the next page.
- `view.previousPage()` — Select the previous page.
- `view.getViewport()` — Read the current page's focus coordinates and zoom.
- `view.getPage(pageIndex?)` — Prepare a page for text operations; omission selects
  the current page. The returned page stays bound to that page after navigation
  or reordering, and becomes invalid when its page or document is removed.
- `view.getPageIdsByTag(tag)` — Read matching IDs in current document order without
  preparing analysis. Android-only; see [page tags](#page-tags-android).
- `view.setMode(mode, options?)` — Enter `'view'`, `'ink'`, or `'text'` synchronously
  once the document is ready. Preserves the viewport and returns a mode session.
  Options apply only to text mode; viewport changes wait for a placement tap.
  Switching modes finishes an open text entry or cancels untapped placement.
  `'view'` is a no-op when no document is open.
- `view.requestPageCoords()` — Wait for one page tap and return `{ pageId, pageIndex,
x, y }`, then return to view mode. Page or mode changes and teardown cancel
  the request. Use `setMode('view')` for Back.
- `view.getState()` — Read document identity, page count, and document-wide dirty state
  synchronously. An empty viewer reports null identity, zero pages, and clean state.
- `view.getSelectedText()` — Read the current native selection as a text handle, or
  `null`. Use it when executing actions; keep `onTextSelectionChange` for button
  availability.
- `view.undo()` — Undo the last edit on the current page.
- `view.redo()` — Redo an undone edit on the current page.
- `view.clear()` — Remove editable ink and module text from the current page as one
  undoable edit. Original PDF content is preserved.
- `view.clearInk()` — Remove only editable ink from the current page as one undoable edit.
- `view.setTextDirection(direction)` — Set the base text direction: `'ltr'`, `'rtl'`,
  or `'auto'` to follow app direction.
- `view.finalize()` — Export to a temporary PDF `file://` URI. Copy it to persistent
  storage before closing the viewer if you need to retain it. On iOS, original
  PDF text may lose search/copy support after export.

### Headless document (Android)

- `document.getState()` — Read document metadata.
- `document.getPage(indexOrTagQuery)` — Obtain a page handle.
- `document.getPageIdsByTag(tag)` — Read matching page IDs.
- `document.addPages({ sources, ...options })` — Import pages from explicit sources.
- `document.removePage(index)`, `document.movePage(from, to)`,
  `document.rotatePage(index, degrees)` — Change pages by document index.
- `document.loadFonts(fonts)` — Preload named fonts.
- `document.finalize()` — Export a new PDF.
- `document.close()` — Release the document; it cannot be reopened.

### Page handle

These methods belong to the `page` returned by a viewer, document, or mode session.
Text resolution and value operations are synchronous.

- `page.getState()` — Read page identity, position, dimensions, rotation, committed
  session content flags, and dirty/undo/redo state.

Dimensions and text bounds use PDF points (1/72 inch) on the displayed, rotated
page, measured rightward and downward from its top-left corner.

- `page.resolveText(options)` — Resolve a complete printed field name or free
  `bounds: { x, y, width, height }` to a numeric ID. Scanned labels need a text layer.
- `page.getTextValue(id)` — Read entered text, falling back to embedded PDF text or `''`.
- `page.setTextValue(id, text, options?)` — Atomically write module text and optional formatting on Android. Pass `''` to remove it and reveal
  any embedded value. Viewer commits are tracked by default; headless commits
  are untracked.
- `page.setTextOptions(id, options)` — Update formatting; omitted options retain their values.
- `page.adjustTextSize(id, delta)` — Increase or decrease font size by page points;
  return the resulting size.
- `page.getTextEntry(id)` — Read the value, value source, and target metadata.
- `page.getTextEntries()` — Read all resolved text targets on the page.
- `page.focusText(id, options?)` — Focus a resolved target without changing mode.
  Available on viewer/session page handles only; headless pages have no focus.
  Options are `zoom`, `verticalAnchor` (`'top'`, `'bottom'`, or `'center'`), and
  `edgeOffset` in page points. Defaults to zoom 2 and center.

On Android, pass `untracked: true` to a programmatic text mutation to update the
permanent base outside undo/redo history:

```ts
page.setTextValue(id, report.number, { untracked: true });
```

The option defaults to `false` and applies only to that call.
Headless documents retain all edits without undo history or content dirty state.

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

- `text.getValue()` — Read the current value.
- `text.setValue(text, options?)` — Update text and optional formatting on Android; `''` removes module text.
- `text.setOptions(options)` — Update formatting.
- `text.adjustSize(delta)` — Adjust font size by page points and return the result.

### Android debug recording

Available in Android debug builds:

- `view.startDebugRecording()` — Clear the bounded trace and start recording.
- `view.stopDebugRecording()` — Stop recording.
- `view.exportDebugRecording()` — Export the stopped trace as replayable CSV.

## Events and paging

- `onStateChange` — Document state, viewer mode/error, and `pageIndex`/`pageCount`
  for a page counter. `pageIndex` is zero-based, or `null` without a document.
- `onPageChange` — Active page ID, dimensions, rotation, and undo/redo availability.
- `onTextSelectionChange` — Selected text ID and page ID, or `null`.
- `onZoomChange` — Settled zoom relative to page fit: `1` is fitted, above `1`
  is zoomed in, below `1` is zoomed out.
- `pagerDirection="rtl"` — Right-to-left paging; omission follows app direction.

Events fire only when their reported values change. Use `view.getState()` or
`document.getState()` for global metadata and `page.getState()` for page details, including content flags
and dirty state.

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
`pageCount`, `getPage(indexOrTagQuery)`, `getPageIdsByTag(tag)`, `addPages({ sources })`, `removePage(index)`,
`movePage(fromIndex, toIndex)`, and `rotatePage(index, 90 | 180 | 270)`.
Use `document.getState()` or `page.getState()` to inspect metadata. Headless text
edits require no focus and create no undo history; structural edits still mark
the document dirty. `finalize()` exports a new PDF without changing the source.
The output file remains yours after closing the document.
`close()` immediately rejects new commands and reads, including `pageCount` and
`getState()`. It is terminal, idempotent, and resolves after admitted work and native
resource cleanup complete. Retained page handles reject edits after close.

### Page tags (Android)

Pass `tag` to `open()`, `openDoc()`, or `addPages()` to label all pages loaded by
that call. Tags stay with pages when reordered, but are not saved in exported PDFs.

Both `view` and `document` support `getPageIdsByTag(tag)` and
`getPage({ tag, index? })`. IDs follow current page order; the query prepares one
match and defaults to the first. `session.getPage()` also accepts this query.

```ts
await document.addPages({ sources: [templateUri], tag: 'report' });
const ids = document.getPageIdsByTag('report');
if (ids.length > 0) {
  const page = await document.getPage({ tag: 'report' });
}
```

### Headless editing example

```ts
import { openDoc } from '@grego5/react-native-inksign-pdf';

const document = await openDoc(file.uri);
try {
  await document.loadFonts([{ name: 'template', uri: bundledFontUri }]);
  const page = await document.getPage(0);
  const id = page.resolveText({ bounds: template.reportNumberBounds });
  page.setTextValue(id, report.number, {
    font: 'template',
    alignment: 'center',
    maxLines: 1,
  });
  const outputUri = await document.finalize();
} finally {
  await document.close();
}
```

On Android, both viewer and headless APIs support `loadFonts([{ name, uri }])`.
Load a static `.ttf` from a local or bundled asset URI, then pass its name as
`font` when resolving, inserting, or formatting text. Omit `font` to keep the
current selection; use `font: null` to restore the system font.
