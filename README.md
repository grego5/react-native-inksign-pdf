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

export function SigningView({ pdfPath }: { pdfPath: string }) {
  const pdf = useRef<InkSignViewHandle>(null);
  const [page, setPage] = useState<PageInfo | null>(null);
  const [savedPath, setSavedPath] = useState('');

  async function openPdf() {
    const info = await pdf.current?.open(pdfPath);
    if (info) setPage(info);
  }

  async function savePdf() {
    const path = await pdf.current?.finalize();
    if (path) setSavedPath(path);
  }

  return (
    <View style={{ flex: 1 }}>
      <InkSignView ref={pdf} style={{ flex: 1 }} strokeColor="#111827" onPageChange={setPage} />
      {page && (
        <Text>
          Page {page.pageIndex + 1} of {page.pageCount}
        </Text>
      )}
      <Button title="Open PDF" onPress={() => void openPdf()} />
      <Button title="Draw" onPress={() => pdf.current?.setInkMode()} />
      <Button title="Place text" onPress={() => pdf.current?.setTextMode()} />
      <Button title="Undo" onPress={() => pdf.current?.undo()} />
      <Button title="Save PDF" onPress={() => void savePdf()} />
      {savedPath !== '' && <Text>Saved to {savedPath}</Text>}
    </View>
  );
}
```

Tap the page after choosing **Draw** or **Place text**. `finalize()` returns a
temporary PDF path; copy the file if it needs to remain available after the
signing view closes.

On Android, an optional fallback font can use one shared local cache file. Set
`uri` to the app's writable font file and `url` to its download source; a valid
file already at `uri` is reused:

```tsx
<InkSignView androidFallbackFont={{ url: fontDownloadUrl, uri: fontCacheFileUri }} />
```

## Common actions

Use `setViewMode()`, `setInkMode()`, or `setTextMode()` to choose an input mode.
Omit options to preserve the viewport; pass `{}` to fit the page, or
`{ zoom: 3, x: 200, y: 600 }` to zoom and focus. Text-mode viewport changes
apply after the placement tap. Text finishes in view mode; switching modes also
finishes an open text draft.

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

Add text directly to a page. Bounds use PDF points from the displayed page's
top-left, including its current rotation:

```ts
pdf.current?.insertTextAt('Approved', { x: 48, y: 72, width: 172, height: 68 });
```

Fill a field beside a printed label:

```ts
await pdf.current?.insertTextByFieldName('Ada Lovelace', 'Name');
```

Field methods find a printed label with an adjacent writing line. They require
extractable PDF text; scanned labels need a text layer. Use `occurrence: 'last'`
to select the last eligible label instead of the first.

Zoom to a signing line without adding text:

```ts
await pdf.current?.focusPageByFieldName('Signature', {
  zoom: 3,
  verticalAnchor: 'bottom',
  edgeOffset: 24,
  setInkMode: true,
});
```

This example leaves room above the line and enables drawing. Use `top` for room
below, or `center` to center the line. `edgeOffset` is the distance from the
viewport edge in PDF points. Omitted focus options use zoom 2 and center the line.
Set `direction: 'ltr'` or `'rtl'` to choose a writing line on the label's right
or left; `auto` follows the app direction.

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
