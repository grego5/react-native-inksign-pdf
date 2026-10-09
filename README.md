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
  type PageInfo,
} from '@grego5/react-native-inksign-pdf';

export function SigningView({ pdfPath, sessionId }: { pdfPath: string; sessionId: string }) {
  const pdf = useRef<InkSignViewHandle>(null);
  const [page, setPage] = useState<PageInfo | null>(null);
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
        onStateChange={(state) => {
          if (state.error) console.error(state.error);
        }}
        style={{ flex: 1 }}
        strokeColor="#111827"
        onPageChange={setPage}
      />
      {page && (
        <Text>
          Page {page.pageIndex + 1} of {page.pageCount}
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
- `requestPageCoords()` — Wait for one page tap and return `{ pageId, pageIndex,
x, y }`, then return to view mode. Page or mode changes and teardown cancel
  the request. Use `setMode('view')` for Back.
- `hasInk()` — Check whether the current page has committed ink.
- `undo()` — Undo the last edit on the current page.
- `redo()` — Redo an undone edit on the current page.
- `clear()` — Remove editable ink and module text from the current page as one
  undoable edit. Original PDF content is preserved.
- `clearInk()` — Remove only editable ink from the current page as one undoable edit.
- `setTextDirection(direction)` — Set the base text direction: `'ltr'`, `'rtl'`,
  or `'auto'` to follow app direction.
- `finalize()` — Export to a temporary PDF `file://` URI. Copy it to persistent
  storage before closing the viewer if you need to retain it.

### Prepared page

Prepare once with `getPage()`; text resolution and value operations are synchronous.

- `resolveText(options)` — Resolve a complete printed field name or free
  `bounds: { x, y, width, height }` to a numeric ID. Scanned labels need a text layer.
- `getTextValue(id)` — Read entered text, falling back to embedded PDF text or `''`.
- `setTextValue(id, text)` — Write module text. Pass `''` to remove it and reveal
  any embedded value. Committed edits are undoable.
- `setTextOptions(id, options)` — Update formatting; omitted options retain their values.
- `adjustTextSize(id, delta)` — Increase or decrease font size by page points;
  return the resulting size.
- `getTextEntry(id)` — Read the value, value source, and target metadata.
- `getTextEntries()` — Read all resolved text targets on the page.
- `focusText(id, options?)` — Focus a resolved target without changing mode.
  Options are `zoom`, `verticalAnchor` (`'top'`, `'bottom'`, or `'center'`), and
  `edgeOffset` in page points. Defaults to zoom 2 and center.

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

### Android debug recording

Available in Android debug builds:

- `startDebugRecording()` — Clear the bounded trace and start recording.
- `stopDebugRecording()` — Stop recording.
- `exportDebugRecording()` — Export the stopped trace as replayable CSV.

## Events and paging

- `onStateChange` — Viewer state, including mode, document identity, edit history,
  and load error.
- `onPageChange` — Current page information after opening, importing, or changing pages.
- `onTextSelectionChange` — Selected text ID and page ID, or `null`.
- `onZoomChange` — Settled zoom relative to page fit: `1` is fitted, above `1`
  is zoomed in, below `1` is zoomed out.
- `pagerDirection="rtl"` — Right-to-left paging; omission follows app direction.

See the [public API](./src/InkSignView.nitro.ts) for all props and options.

## Examples

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

A valid font at `uri` is reused; otherwise it is downloaded from `url` to that
app-owned cache file.

```tsx
<InkSignView androidFallbackFont={{ url: fontDownloadUrl, uri: fontCacheFileUri }} />
```

