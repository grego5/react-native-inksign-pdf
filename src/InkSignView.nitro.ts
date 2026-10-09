import type {
  HybridObject,
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

/** Opaque RGB stroke color in `#RRGGBB` form. Invalid values are ignored natively. */
export type StrokeColor = string

/** Opaque RGB text/UI color in `#RRGGBB` form. Invalid values use the native default. */
export type TextColor = string

/** Zero-based current page metadata returned by open and page navigation. */
export interface PageInfo {
  /** Zero-based index of the active page; the first page is 0. */
  pageIndex: number
  /** Total number of pages in the document. */
  pageCount: number
  width: number
  height: number
}

/** Fixed text-flow rectangle in canonical PDF page points. x/y are physical top-left coordinates. */
export interface TextAnnotationBounds {
  x: number
  y: number
  width: number
  height: number
}

/** Text presentation options used by direct insertion and dimensioned placement. */
export interface TextAnnotationOptions {
  /** Canonical page-unit font size for this text target. */
  fontSize?: number
  /** Opaque RGB color saved with this text target. */
  color?: TextColor
  /** Base writing direction. `auto` follows the app's resolved layout direction. */
  direction?: TextDirection
  /** Retains at most this many complete lines; zero or omission keeps the full flow region. */
  maxLines?: number
  /** Positions text inside its flow rectangle; start/end follow the resolved direction. */
  alignment?: TextAlignment
  /** Selects which edge fixes the visible block within its flow rectangle. */
  verticalAnchor?: TextVerticalAnchor
}

/** One-shot text placement; viewport changes apply after the tap. Box dimensions are PDF page points. */
export interface TextModeOptions extends ViewportOptions {
  /** Defaults to `auto`, following the app's resolved layout direction. */
  direction?: TextDirection
  /** Supply both dimensions for a fixed hard-bounded box; omit both to auto-size as text grows. */
  width?: number
  /** Supply both dimensions for a fixed hard-bounded box; omit both to auto-size as text grows. */
  height?: number
  /** Maximum complete lines; omission keeps every line that fits. */
  maxLines?: number
  /** Omission aligns to `start`. */
  alignment?: TextAlignment
  /** Omission anchors the initial text block at the top. */
  verticalAnchor?: TextVerticalAnchor
}

/** Focus an already resolved text target without creating an annotation. */
export interface TextFocusOptions {
  /** Positive zoom factor; defaults to 2 and is clamped to the native viewport limits. */
  zoom?: number
  /** Positions the writing rule at the visible top or bottom edge; center ignores edgeOffset. Defaults to center. */
  verticalAnchor?: FieldFocusVerticalAnchor
  /** Distance inward from the selected viewport edge, in PDF page points. */
  edgeOffset?: number
}

/** Options used to resolve a named field or reserve a free text placement. */
export interface ResolveTextOptions extends TextAnnotationOptions {
  /** Complete detected label. Partial labels and substrings do not match. */
  fieldName?: string
  /** Restricts named lookup, or defines placement when fieldName is omitted. */
  bounds?: TextAnnotationBounds
  occurrence?: TextKeyOccurrence
}

export type TextId = number
export type TextValueSource = 'empty' | 'annotation' | 'embedded'
/** Physical pager direction; auto follows the app's layout direction. */
export type PagerDirection = 'auto' | 'ltr' | 'rtl'

/** Current value and target metadata retained by an analyzed page. */
export interface TextEntry {
  id: TextId
  value: string
  fieldName?: string
  bounds?: TextAnnotationBounds
  valueSource: TextValueSource
}

/** Stable native page identity associated with current text selection. */
export interface TextSelection {
  textId: TextId
  pageId: string
}

/** One tap in displayed top-left page points, matching viewport command coordinates. */
export interface PageCoords {
  pageId: string
  pageIndex: number
  x: number
  y: number
}

/** Prepared source analysis and synchronous text operations for one stable page. */
export interface AnalyzedPage extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /** Creates or resolves a text target from page analysis and returns its ID. */
  resolveText(options: ResolveTextOptions): TextId
  /** Returns the target's effective text value. */
  getTextValue(id: TextId): string
  /** Sets the target's entered text; empty text removes module text and preserves source PDF text. */
  setTextValue(id: TextId, text: string): void
  /** Updates the target's text options; omitted fields retain their current values. */
  setTextOptions(id: TextId, options: TextAnnotationOptions): void
  /** Adjusts the native font size by page points and returns the resulting size. */
  adjustTextSize(id: TextId, delta: number): number
  /** Returns one target's value, source, and optional field metadata. */
  getTextEntry(id: TextId): TextEntry
  /** Returns all text targets on this page. */
  getTextEntries(): TextEntry[]
  /** Focuses the target; omitted options use zoom 2 and center it without changing input mode. */
  focusText(id: TextId, options?: TextFocusOptions): Promise<void>
}

/** Document-bound text target; remains usable after selection or page changes. */
export interface TextHandle extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  getValue(): string
  /** Empty text removes module text while preserving embedded PDF content. */
  setValue(text: string): void
  setOptions(options: TextAnnotationOptions): void
  /** Adjusts font size by page points and returns the resulting size. */
  adjustSize(delta: number): number
}

/** Operations scoped to one explicit mode request. Supersession rejects with operation_cancelled. */
export interface ModeSession extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /** Prepares a page bound to this session and its captured document. */
  getPage(pageIndex?: number): Promise<AnalyzedPage>
  /** Temporarily picks one page tap, then restores this session's input mode. */
  requestPageCoords(): Promise<PageCoords>
  /** Preserves the viewport when omitted; an empty object fits the current page. */
  setViewport(options?: ViewportOptions): Promise<void>
}

export type PageType = 'pdf' | 'image'
export type TextDirection = 'ltr' | 'rtl' | 'auto'
export type InputMode = 'view' | 'ink' | 'text'
export type TextAlignment = 'start' | 'end' | 'center'
export type TextVerticalAnchor = 'top' | 'bottom'
export type FieldFocusVerticalAnchor = 'top' | 'bottom' | 'center'
export type TextKeyOccurrence = 'first' | 'last'
export type AddPagesActivePage = 'current' | 'firstAdded' | 'lastAdded'

/** Image page dimensions in PDF points. */
export interface ImagePageSize {
  width: number
  height: number
}

export interface AddPagesOptions {
  /** Restricts the native picker. Omission permits both `pdf` and `image`. */
  type?: PageType
  /** Ordered local file paths or file URLs to import without presenting a picker. */
  sources?: string[]
  /** Dimensions used for every imported image. Defaults to the active page size or portrait A4. */
  imagePageSize?: ImagePageSize
  /** Omit for legacy 200 DPI output; explicit values cap at effective source DPI. */
  targetDpi?: number
  /** JPEG quality for imported image pages, from 0 to 1. Defaults to 0.72. */
  jpegQuality?: number
  /** Page selected after import. Defaults to `current`, or the first added page when creating a document. */
  activePage?: AddPagesActivePage
}

export interface AddPagesResult {
  /** Metadata for the active page; omitted when cancellation leaves no document. */
  pageInfo?: PageInfo
  /** Number of pages added. Cancellation and empty sources resolve with zero. */
  addedPageCount: number
}

export interface ViewerState {
  /** Opaque identity of the published document; null while empty. */
  documentId: string | null
  canUndo: boolean
  canRedo: boolean
  isDirty: boolean
  mode: InteractionMode
  /** Latest document-load failure; cleared when another load starts. */
  error: string | null
}

export type InteractionMode =
  | 'view'
  | 'ink'
  | 'textAdd'
  | 'textEdit'
  | 'pageCoords'

export interface ViewportOptions {
  /** Canonical page focus coordinates; x and y must be supplied together. */
  x?: number
  y?: number
  /** Absolute positive zoom, clamped to native viewport limits. */
  zoom?: number
}

export interface AndroidFallbackFont {
  url: string
  uri: string
  /** Font collection face index. Defaults to 0. */
  collectionIndex?: number
}

export interface Viewport {
  x: number
  y: number
  zoom: number
}

export interface DoubleTapOptions {
  /** Absolute target zoom. The tapped area is centered when possible and clamped to the valid viewport bounds; both zoom-in and fit-out animate. A zoom-in is ignored when the current zoom is already at or above it; later double taps fit the page again. */
  zoom: number
  /** Enter edit mode after the zoom completes. */
  enterEditMode?: boolean
}

export interface InkSignViewProps extends HybridViewProps {
  /** Android PDFium font asset. Reuses uri when present, otherwise downloads url there; iOS ignores this. */
  androidFallbackFont?: AndroidFallbackFont
  strokeColor?: StrokeColor
  strokeMinWidth?: number
  strokeMaxWidth?: number
  strokeSmoothing?: number
  /** Default canonical page-unit font size for new text. Invalid values use 16; valid values are clamped to 8...72. */
  defaultTextFontSize?: number
  /** Color saved with newly created text annotations. Existing annotations keep their saved color. */
  defaultTextColor?: TextColor
  /** Presentation-only outline color for committed text. */
  outlineColor?: TextColor
  /** Presentation-only outline color for selected text. */
  selectedOutlineColor?: TextColor
  /** Opaque editor fill while editing; omitted uses a contrasting fill based on the saved text color. Native UI applies the opacity. */
  editorBackgroundColor?: TextColor
  /** Optional presentation-only fill color for selected, non-editing text. Native UI applies the fill opacity. */
  selectedBackgroundColor?: TextColor
  doubleTap?: DoubleTapOptions
  /** Keep the active text editor visible above the native keyboard. Defaults to true. */
  keyboardAvoidanceEnabled?: boolean
  /** Controls which physical side contains the logical next page. Defaults to app direction. */
  pagerDirection?: PagerDirection
  onStateChange?: (event: ViewerState) => void
  onPageChange?: (event: PageInfo) => void
  /** Settled zoom relative to page fit: 1 is fitted, below 1 is zoomed out. */
  onZoomChange?: (zoom: number) => void
  onTextSelectionChange?: (selection: TextSelection | null) => void
}

export interface InkSignViewMethods extends HybridViewMethods {
  /** Opens a local PDF or JPEG path/file:// URI. JPEG becomes one A4 page; omitted options fit. */
  open(path: string, options?: ViewportOptions): Promise<PageInfo>
  /** Closes in FIFO order; omitted `cancelPending` is false. Pass true to cancel pending work. */
  close(cancelPending?: boolean): Promise<void>
  /** Adds pages from `sources`, or opens the native picker when sources are omitted. */
  addPages(options?: AddPagesOptions): Promise<AddPagesResult>
  /** Removes the active page. The document must retain at least one page. */
  removePage(): Promise<PageInfo>
  /** Moves the active page to the zero-based destination index. */
  movePage(pageIndex: number): Promise<PageInfo>
  /** Rotates the active page clockwise by 90, 180, or 270 degrees and persists the rotation to export. */
  rotatePage(degrees: number): Promise<PageInfo>
  /** Selects the next page; stays on the last page at the end. */
  nextPage(): void
  /** Selects the previous page; stays on the first page at the beginning. */
  previousPage(): void
  /** Returns the active page's current focus coordinates and zoom. */
  getViewport(): Viewport
  /** Enters pageCoords mode on the active page without changing the viewport. One tap resolves and returns to view mode; page/mode changes or teardown cancel it. */
  requestPageCoords(): Promise<PageCoords>
  /** Returns whether the active page has committed ink; undo, redo, clear, and page changes are reflected. */
  hasInk(): boolean
  /** Reads native selection synchronously; null when no text is selected. Handle operations reject after document/page/target invalidation. */
  getSelectedText(): TextHandle | null
  /** Prepares a document-bound page that survives mode changes; omission selects the active page. */
  getPage(pageIndex?: number): Promise<AnalyzedPage>
  /** Synchronously enters a mode, preserves the viewport, and supersedes the previous session. Requires a ready document. Options apply only to text placement; their viewport changes wait for a valid tap. */
  setMode(mode: InputMode, options?: TextModeOptions): ModeSession
  /** Undoes the last history change on the active page; no-op when history is empty. */
  undo(): void
  /** Redoes the next history change on the active page; no-op when redo history is empty. */
  redo(): void
  /** Clears editable ink and text from the active page. */
  clear(): void
  /** Clears only editable ink on the active page as one undoable change. */
  clearInk(): void
  /** Sets the base direction for new text; `auto` follows app RTL policy and is saved with each annotation. */
  setTextDirection(direction: TextDirection): void
  /** Returns a temporary local PDF file URI (file://). */
  finalize(): Promise<string>
  /** Android debug builds only. Clears the bounded native trace and starts recording. */
  startDebugRecording(): void
  /** Android debug builds only. Stops accepting trace operations. */
  stopDebugRecording(): void
  /** Android debug builds only. Writes the stopped trace as replayable CSV. */
  exportDebugRecording(): Promise<string>
}

export type InkSignView = HybridView<
  InkSignViewProps,
  InkSignViewMethods
>
