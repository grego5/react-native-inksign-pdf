# iOS viewport and input

- **View mode:** `PDFView` owns pan, pinch, momentum, and page navigation.
  Its gestures yield when the text overlay admits a touch for selection,
  editing, or finishing an open editor. Armed placement accepts a page tap.
- **Edit mode:** PDF navigation gestures are suspended. PencilKit owns drawing
  touches; the separate text surface owns placement, selection, editing, and
  movement on text hit areas. View-mode PDF gestures return when editing ends.
- Text placement uses the tap as the first caret edge. One outer text rectangle
  describes the editor, selection outline, and committed bounds.
- TextKit determines the editor's final width, wrapping, caret, and selection
  geometry. Committed text retains those bounds and uses the same font and
  paragraph style.
- Explicit text direction remains fixed. Automatic direction follows the
  reported keyboard language while a new editor is empty, locks when content
  begins, and may follow the keyboard again after the text is erased. Committed
  annotations retain their saved direction.
- Editing preserves the current PDFView zoom. The viewport pans to keep the text
  outline and active caret within a 24-point margin when the keyboard-adjusted
  visible area permits; viewport movement does not change canonical annotation
  geometry.
- Placement converts one valid tap into page coordinates. Empty drafts are
  transient editor state.
- History and export use committed content. Tool begin/end callbacks delimit ink
  changes in page-local history.
- PDFKit maps canonical page coordinates into the visible page overlay. The
  document coordinator remains the authority for page identity and committed
  content.
