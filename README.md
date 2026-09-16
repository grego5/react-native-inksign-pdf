# @grego5/react-native-inksign-pdf

- PDF ink signature drawing module for React Native.
- Displays loaded PDF as background. Including swipe/method pagination.
- Using fallback overlay for displaying unsupported fonts processed with pdfium.
- Supports velocity-driven ink, text annotations, and histroy.
- Android using custom c++ stroke engine, integrating Google Ink line modeling algorithms, and low-latency front buffer api for zero lag drawing before committing to standard render node. For some reason uncommon technique in most apps.
- iOS basic compatibility using PencilKit. No web support.
- Export changes written to new PDF as vector path, preserving minimal size and high quality on Android, rasterized overlay fallback on iOS.

Intended workflow: open pdf, double click an area or dedicated button to enter edit mode, zoom into tapped area or prefined coordinates,
darw a signature, save to new file. The brush doesn't scale with zoom level, but the drawn shape does.

![Screenshot 1](example/screenshot.jpg)

## Requirements

- React Native `>=0.86.0 <0.87.0`
- Node.js 20 or newer
- Android 12/API 31 or newer with Android S extension 18 or newer
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

```tsx
import { useRef, useState } from 'react';
import { Button, StyleSheet, Text, View } from 'react-native';
import {
  PdfView,
  type PageInfo,
  type PdfViewHandle,
  type StateChangeEvent,
} from '@grego5/react-native-inksign-pdf';

export function SigningView({ pdfPath }: { pdfPath: string }) {
  const pdf = useRef<PdfViewHandle>(null);
  const [page, setPage] = useState<PageInfo | null>(null);
  const [state, setState] = useState<StateChangeEvent>({
    canUndo: false,
    canRedo: false,
    isDirty: false,
    mode: 'view',
  });
  const [status, setStatus] = useState('Choose a PDF to begin');

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
      <PdfView
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
          onPress={() => void pdf.current?.previousPage().then(setPage)}
        />
        <Button
          title="Next"
          disabled={!page || page.pageIndex === page.pageCount - 1}
          onPress={() => void pdf.current?.nextPage().then(setPage)}
        />
        <Button title="Draw" disabled={!page} onPress={() => void pdf.current?.enterEditMode()} />
        <Button title="View" disabled={!page} onPress={() => void pdf.current?.enterViewMode()} />
        <Button
          title="Place text"
          disabled={!page}
          onPress={() => void pdf.current?.insertAnnotationOn()}
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

`open()` accepts a local PDF path and starts in view mode. Keep the source file
readable while the view is mounted. `finalize()` returns the path to the signed
PDF; copy that file to durable application storage before unmounting the view.

## Component API

### Props

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
<PdfView
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
open(path, viewport?)
nextPage()
previousPage()
getViewport()
enterEditMode(viewport?)
enterViewMode(viewport?)
undo()
redo()
clear()
insertAnnotationOn()
insertAnnotationOff()
increaseTextSize()
decreaseTextSize()
removeTextAnnotation()
finalize()
```

`open()` and page navigation return:

```ts
{
  (pageIndex, pageCount, width, height);
}
```

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
- Edit mode accepts finger or stylus input for velocity-driven ink and keeps the
  viewport fixed.
- `insertAnnotationOn()` arms one text placement; the next page tap opens the
  native text editor.
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

- [Public API spec](./src/PdfView.nitro.ts)
- [Architecture and invariants](./.agents/skills/inksign-pdf-docs/references/architecture.md)
- [Android input and viewport behavior](./.agents/skills/inksign-pdf-docs/references/android/viewport-input.md)
- [iOS input and viewport behavior](./.agents/skills/inksign-pdf-docs/references/swift-ios/viewport-input.md)

