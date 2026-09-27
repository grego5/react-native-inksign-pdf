import type {
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

/** Canonical PDF page position in points, measured from the top-left corner. */
export interface PagePosition {
  x: number
  y: number
}

/** Optional flow limits in canonical PDF page points. Limits are absolute page coordinates. */
export interface TextAnnotationOptions {
  /** Base writing direction. `auto` follows the app's resolved layout direction. */
  direction?: TextDirection
  /** Opposite horizontal edge: rightward for LTR, leftward for RTL. Defaults to the page edge. */
  xLimit?: number
  /** Bottom edge for wrapped lines. Defaults to the page bottom. */
  yLimit?: number
}

export type PageType = 'pdf' | 'image'
export type TextDirection = 'ltr' | 'rtl' | 'auto'

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
}

export interface AddPagesResult {
  /** Metadata for the active page; omitted when cancellation leaves no document. */
  pageInfo?: PageInfo
  /** Number of pages added. Cancellation and empty sources resolve with zero. */
  addedPageCount: number
}

export interface StateChangeEvent {
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
  x?: number
  y?: number
  zoom?: number
}

export interface PdfFallbackFont {
  path: string
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
  /** Android-only PDFium fallback font; iOS uses Core Text system fallback. */
  fallbackFont?: PdfFallbackFont
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
  onStateChange?: (event: StateChangeEvent) => void
  onPageChange?: (event: PageInfo) => void
}

export interface InkSignViewMethods extends HybridViewMethods {
  open(path: string, options?: ViewportOptions): Promise<PageInfo>
  addPages(options?: AddPagesOptions): Promise<AddPagesResult>
  removePage(): Promise<PageInfo>
  movePage(pageIndex: number): Promise<PageInfo>
  nextPage(): void
  previousPage(): void
  getViewport(): Viewport
  enterEditMode(viewport?: ViewportOptions): void
  enterViewMode(viewport?: ViewportOptions): void
  undo(): void
  redo(): void
  clear(): void
  /** Commits text at an active-page position with optional canonical page-point flow limits. */
  addTextAnnotation(text: string, position: PagePosition, options?: TextAnnotationOptions): void
  /** Sets the base direction for new text; `auto` follows app RTL policy and is saved with each annotation. */
  setTextDirection(direction: TextDirection): void
  /** Arms one-shot native text placement at the next valid page tap. */
  insertAnnotationOn(): void
  /** Cancels a pending one-shot text placement, if any. */
  insertAnnotationOff(): void
  increaseTextSize(): number
  decreaseTextSize(): number
  removeTextAnnotation(): void
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
