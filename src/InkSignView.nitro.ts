import type {
  HybridObject,
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

import type { NamedFontSource } from './InkSignDocument.nitro'

/** Opaque RGB stroke color in `#RRGGBB` form. Invalid values are ignored natively. */
export type StrokeColor = string

/** Opaque RGB text/UI color in `#RRGGBB` form. Invalid values use the native default. */
export type TextColor = string

/** Active-page metadata and history state reported by onPageChange. */
export interface PageChangeEvent {
  /** Stable identity for this page within the open document. */
  pageId: string
  /** Visible page width in PDF points (1/72 inch), after rotation; honors imported CropBox. */
  width: number
  /** Visible page height in PDF points (1/72 inch), after rotation; honors imported CropBox. */
  height: number
  /** Clockwise page rotation in degrees: 0, 90, 180, or 270. */
  rotation: number
  canUndo: boolean
  canRedo: boolean
}

/** Current page state in displayed page coordinates, read imperatively. */
export interface PageInfo extends PageChangeEvent {
  /** Nonunique session tag assigned when opening or importing this page. */
  tag?: string
  /** Committed InkSign content in this session; excludes live drafts and imported PDF content. */
  hasInk: boolean
  hasText: boolean
  /** Current zero-based index of this page; the first page is 0. */
  pageIndex: number
  /** Total number of pages in the document. */
  pageCount: number
  /** Whether this page has applied tracked edits; redo-only history and untracked content are clean. */
  isDirty: boolean
}

/** Document-wide metadata; empty viewers report null identity, zero pages, and clean state. */
export interface DocumentState {
  documentId: string | null
  pageCount: number
  /** Includes structural changes and dirty committed content on any page. */
  isDirty: boolean
}

/** Text-flow rectangle in displayed PDF page points, matching PageInfo width/height.
 * Origin is the rotated visible page's top-left; x increases rightward and y downward.
 * Existing text keeps its captured layout orientation when the page rotates.
 */
export interface TextAnnotationBounds {
  x: number
  y: number
  width: number
  height: number
}

/** Text presentation options used by direct insertion and dimensioned placement. */
export interface TextPresentationOptions {
  /** Preloaded owner-local font name; null restores the system font. */
  font?: string | null
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

export interface TextAnnotationOptions extends TextPresentationOptions {
  /** Android: applies this programmatic edit to the permanent base. Defaults to false; ignored for items with retained tracked edits. This is per-call, not saved formatting. */
  untracked?: boolean
}

/** One-shot text placement; viewport changes apply after the tap. Box dimensions are PDF page points. */
export interface TextModeOptions extends ViewportOptions {
  font?: string | null
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
export interface InputTargetFocusOptions {
  /** Positive zoom factor; defaults to 2 and is clamped to the native viewport limits. */
  zoom?: number
  /** Positions the writing rule at the visible top or bottom edge; center ignores edgeOffset. Defaults to center. */
  verticalAnchor?: FieldFocusVerticalAnchor
  /** Distance inward from the selected viewport edge, in PDF page points. */
  edgeOffset?: number
}

/** Detect an input underline beside a complete printed label. */
export interface ResolveInputUnderlineOptions extends TextPresentationOptions {
  /** Complete detected label. Partial labels and substrings do not match. */
  fieldName: string
  /** Restricts label lookup to this displayed region. */
  bounds?: TextAnnotationBounds
  occurrence?: TextKeyOccurrence
}

/** Define an input area directly in displayed page coordinates. */
export interface CreateInputAreaOptions extends TextPresentationOptions {
  bounds: TextAnnotationBounds
}

export type InputTargetId = number
export type TextValueSource = 'empty' | 'annotation' | 'embedded'
/** Physical pager direction; auto follows the app's layout direction. */
export type PagerDirection = 'auto' | 'ltr' | 'rtl'

/** Current value and target metadata retained by an analyzed page. */
export interface InputTarget {
  id: InputTargetId
  value: string
  fieldName?: string
  /** Axis-aligned bounds in the page's current displayed coordinates. */
  bounds?: TextAnnotationBounds
  valueSource: TextValueSource
}

/** Stable native page identity associated with current text selection. */
export interface TextSelection {
  textId: InputTargetId
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
export interface PageTextMethods {
  /** Detects a label and adjacent underline, returning an input target ID. */
  resolveInputUnderline(options: ResolveInputUnderlineOptions): InputTargetId
  /** Creates or reuses an input area with explicit bounds. */
  createInputArea(options: CreateInputAreaOptions): InputTargetId
  /** Returns the target's effective text value. */
  getTextValue(id: InputTargetId): string
  /** Sets the target's entered text; empty text removes module text and preserves source PDF text. */
  setTextValue(id: InputTargetId, text: string, options?: TextAnnotationOptions): void
  /** Updates the target's text options; omitted fields retain their current values. */
  setTextOptions(id: InputTargetId, options: TextAnnotationOptions): void
  /** Adjusts the native font size by page points and returns the resulting size. */
  adjustTextSize(id: InputTargetId, delta: number): number
  /** Returns one target's value, source, and optional field metadata. */
  getInputTarget(id: InputTargetId): InputTarget
  /** Returns all text targets on this page. */
  getInputTargets(): InputTarget[]
}

export interface AnalyzedPage extends HybridObject<{ ios: 'swift'; android: 'kotlin' }>, PageTextMethods {
  /** Reads current metadata for this stable page without switching the viewer. */
  getState(): PageInfo
  /** Focuses the target; omitted options use zoom 2 and center it without changing input mode. */
  focusInputTarget(id: InputTargetId, options?: InputTargetFocusOptions): Promise<void>
}

/** Document-bound text target; remains usable after selection or page changes. */
export interface TextHandle extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  getValue(): string
  /** Empty text removes module text while preserving embedded PDF content. */
  setValue(text: string, options?: TextAnnotationOptions): void
  setOptions(options: TextAnnotationOptions): void
  /** Adjusts font size by page points and returns the resulting size. */
  adjustSize(delta: number): number
}

/** Operations scoped to one explicit mode request. Supersession rejects with operation_cancelled. */
export interface ModeSession extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  /** Prepares a page bound to this session and its captured document. */
  getPage(pageIndex?: PageQuery): Promise<AnalyzedPage>
  /** Temporarily picks one page tap, then restores this session's input mode. */
  requestUserTap(): Promise<PageCoords>
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

export interface TaggedPageQuery {
  tag: string
  /** Zero-based position among matching pages in current document order. Defaults to 0. */
  index?: number
}

export type PageQuery = number | TaggedPageQuery

/** Image page dimensions in PDF points. */
export interface ImagePageSize {
  width: number
  height: number
}

export interface AddPagesOptions {
  /** Session-only tag assigned to every page imported by this call. */
  tag?: string
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

export interface ViewerState extends DocumentState {
  mode: InteractionMode
  /** Latest document-load failure; cleared when another load starts. */
  error: string | null
  /** Active zero-based page index; null when no document is open. */
  pageIndex: number | null
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

export interface ViewOpenOptions extends ViewportOptions {
  /** Session-only tag assigned to every opened page. */
  tag?: string
}

export interface AndroidFallbackFont {
  /** Font source: HTTP(S), local file, content/resource URI, or packaged Android resource name. */
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
  /** Android PDFium font source, loaded into memory for the document session; iOS ignores this. */
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
  /** Active-page metadata after navigation or committed edits; deduplicated. */
  onPageChange?: (event: PageChangeEvent) => void
  /** Settled zoom relative to page fit: 1 is fitted, below 1 is zoomed out. */
  onZoomChange?: (zoom: number) => void
  onTextSelectionChange?: (selection: TextSelection | null) => void
}

export interface InkSignViewMethods extends HybridViewMethods {
  /** Preload named text fonts once per viewer.  */
  loadFonts(fonts: NamedFontSource[]): Promise<void>
  /** Opens a local PDF or JPEG path/file:// URI. JPEG becomes one A4 page; omitted options fit. */
  open(path: string, options?: ViewOpenOptions): Promise<PageInfo>
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
  requestUserTap(): Promise<PageCoords>
  /** Synchronous document-wide metadata, independent of the active page. */
  getState(): DocumentState
  /** Reads native selection synchronously; null when no text is selected. Handle operations reject after document/page/target invalidation. */
  getSelectedText(): TextHandle | null
  /** Prepares a document-bound page that survives mode changes; omission selects the active page. */
  getPage(pageIndex?: PageQuery): Promise<AnalyzedPage>
  /** Reads matching IDs in current document order without preparing analysis. */
  getPageIdsByTag(tag: string): string[]
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
