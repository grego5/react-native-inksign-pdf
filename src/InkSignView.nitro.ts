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
  pageIndex: number
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
  direction?: TextDirection
  width?: number
  height?: number
  maxLines?: number
  alignment?: TextAlignment
  verticalAnchor?: TextVerticalAnchor
}

/** Focus a page on a matching label's adjacent rule without creating an annotation. */
export interface FieldFocusOptions {
  occurrence?: TextKeyOccurrence
  /** Rule side follows text-placement direction policy: explicit LTR/RTL or auto app direction. */
  direction?: TextDirection
  /** Positive zoom factor; defaults to 2 and is clamped to the native viewport limits. */
  zoom?: number
  /** Positions the writing rule at the visible top or bottom edge; center ignores edgeOffset. Defaults to center. */
  verticalAnchor?: FieldFocusVerticalAnchor
  /** Distance inward from the selected viewport edge, in PDF page points. */
  edgeOffset?: number
  /** Enables ink after successful focus. Omission or false preserves the current mode. */
  setInkMode?: boolean
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
  hasValue: boolean
  valueSource: TextValueSource
}

/** Stable native page identity associated with current text selection. */
export interface TextSelection {
  textId: TextId
  pageId: string
}

/** Prepared source analysis and synchronous text operations for one stable page. */
export interface AnalyzedPage extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  resolveText(options: ResolveTextOptions): TextId
  getTextValue(id: TextId): string
  setTextValue(id: TextId, text: string): void
  clearText(id: TextId): void
  setTextOptions(id: TextId, options: TextAnnotationOptions): void
  /** Adjusts the native font size by page points and returns the resulting size. */
  adjustTextSize(id: TextId, delta: number): number
  getTextEntry(id: TextId): TextEntry
  getTextEntries(): TextEntry[]
  focusText(id: TextId, options?: FieldFocusOptions): Promise<void>
}

export type PageType = 'pdf' | 'image'
export type TextDirection = 'ltr' | 'rtl' | 'auto'
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
}

export type InteractionMode =
  | 'view'
  | 'draw'
  | 'textPlacement'
  | 'textSelected'
  | 'textEditing'

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
  /** Reports settled zoom above fitted scale; at or below fit reports false. */
  onZoomedInChange?: (zoomedIn: boolean) => void
  onTextSelectionChange?: (selection: TextSelection | null) => void
}

export interface InkSignViewMethods extends HybridViewMethods {
  /** FIFO document open; earlier document operations finish first. */
  open(path: string, options?: ViewportOptions): Promise<PageInfo>
  /** Closes in FIFO order. Pass true to cancel pending work and prevent late publication. */
  close(cancelPending?: boolean): Promise<void>
  addPages(options?: AddPagesOptions): Promise<AddPagesResult>
  removePage(): Promise<PageInfo>
  movePage(pageIndex: number): Promise<PageInfo>
  /** Rotates the active page clockwise by 90, 180, or 270 degrees and persists the rotation to export. */
  rotatePage(degrees: number): Promise<PageInfo>
  nextPage(): void
  previousPage(): void
  getViewport(): Viewport
  /** Returns whether the active page has committed ink; undo, redo, clear, and page changes are reflected. */
  hasInk(): boolean
  /** Prepares source analysis for the captured or explicitly indexed page without navigating. */
  getPage(pageIndex?: number): Promise<AnalyzedPage>
  /** FIFO ink mode; empty viewers resolve unchanged. Omission preserves the viewport; an empty object fits. */
  setInkMode(viewport?: ViewportOptions): Promise<void>
  /** FIFO view mode; empty viewers resolve unchanged. Omission preserves the viewport; an empty object fits. */
  setViewMode(viewport?: ViewportOptions): Promise<void>
  undo(): void
  redo(): void
  clear(): void
  /** Sets the base direction for new text; `auto` follows app RTL policy and is saved with each annotation. */
  setTextDirection(direction: TextDirection): void
  /** FIFO text mode; empty viewers resolve unchanged. Omission preserves the viewport; an empty object fits after the tap. */
  setTextMode(options?: TextModeOptions): Promise<void>
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
