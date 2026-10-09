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
      <Button title="Draw" onPress={() => pdf.current?.setInkMode()} />
      <Button title="Place text" onPress={() => pdf.current?.setTextMode()} />
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

On Android, `androidFallbackFont` reuses a valid font at `uri` or downloads it
from `url` to that app-owned cache file:

```tsx
<InkSignView androidFallbackFont={{ url: fontDownloadUrl, uri: fontCacheFileUri }} />
```

## Common actions

Use `setViewMode()`, `setInkMode()`, and `setTextMode()` to switch modes. Omit
options to keep the current viewport, pass `{}` to fit the page, or set values
such as `{ zoom: 3, x: 200, y: 600 }` to zoom and focus. Text-mode viewport
options take effect when you tap to place text. Finishing text returns to view
mode; switching modes finishes any open text entry first.

Call `getPageCoords()` and tap the page to get coordinates; the viewer returns
to view mode afterward. `onZoomChange` reports settled zoom relative to page fit:
`1` is fitted, above `1` is zoomed in, and below `1` is zoomed out.

Use `clearInk()` to clear the current page's editable ink, or
`page.clearText(id)` to remove selected text. Both are undoable. Cancel pending
text placement with `setViewMode()`. `clear()` clears both ink and text.

```ts
const target = await view.getPageCoords(); // pageId, pageIndex, x, y
await view.setInkMode({ zoom: 3, x: target.x, y: target.y });
```

Use `setViewMode()` for Back. Page or mode changes, replacement, close, and
unmount reject the request with `operation_cancelled`.

Add local PDF or image pages:

```ts
await pdf.current?.addPages({
  sources: [imagePath],
  imagePageSize: { width: 420, height: 594 },
  activePage: 'lastAdded',
});
```

`addPages()` keeps the current page selected by default. Use `firstAdded` or
`lastAdded` to select an imported page.

Fill an empty field by its printed name:

```ts
const page = await pdf.current?.getPage();
if (page) {
  const id = page.resolveText({ fieldName: 'Name' });
  if (!page.getTextValue(id)) page.setTextValue(id, 'Ada Lovelace');
}
```

Use the full field name; scanned PDFs need a text layer. For free placement,
pass `bounds: { x, y, width, height }` instead of `fieldName`.
Set `pagerDirection="rtl"` for right-to-left paging.
Use `page.adjustTextSize(id, 1)` or `-1` for relative text sizing.

Rotate the active page clockwise by 90, 180, or 270 degrees. The exported PDF
keeps that orientation:

```ts
await pdf.current?.rotatePage(90);
```

Use `nextPage()`, `previousPage()`, `undo()`, `redo()`, and `clear()` for
navigation and editing.
`hasInk()` reports whether the active page has committed ink.
See the [public API](./src/InkSignView.nitro.ts) for all props,
options, and methods.
