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

/** Fixed text-flow rectangle in canonical PDF page points. x/y are physical top-left coordinates. */
export interface TextAnnotationBounds {
  x: number
  y: number
  width: number
  height: number
}

/** Text presentation options used by direct insertion and dimensioned placement. */
export interface TextAnnotationOptions {
  /** Base writing direction. `auto` follows the app's resolved layout direction. */
  direction?: TextDirection
  /** Retains at most this many complete lines; zero or omission keeps the full flow region. */
  maxLines?: number
  /** Positions text inside its flow rectangle; start/end follow the resolved direction. */
  alignment?: TextAlignment
  /** Selects which edge fixes the visible block within its flow rectangle. */
  verticalAnchor?: TextVerticalAnchor
}

/** Optional manual-placement box dimensions, with the tap as the rectangle's top-left corner. */
export interface TextPlacementOptions {
  direction?: TextDirection
  width?: number
  height?: number
  maxLines?: number
  alignment?: TextAlignment
  verticalAnchor?: TextVerticalAnchor
}

/**
 * Options for searching extractable source text on the page selected when the
 * command is called and inserting beside a matching key and horizontal rule.
 * Matches without a usable same-row rule on the resolved direction's side are
 * skipped; if the key exists but no eligible match remains, the command rejects
 * with `text_rule_not_found`.
 */
export interface TextInsertionByKeyOptions extends TextAnnotationOptions {
  /** Selects the first (default) or last eligible key match in page order. */
  occurrence?: TextKeyOccurrence
}

/** Focus a page on a matching label's adjacent rule without creating an annotation. */
export interface FieldFocusOptions {
  occurrence?: TextKeyOccurrence
  /** Rule side follows text-placement direction policy: explicit LTR/RTL or auto app direction. */
  direction?: TextDirection
  /** Positive zoom factor; defaults to 2 and is clamped to the native viewport limits. */
  zoom?: number
  /** Enable freehand drawing after focusing. Omission preserves the current mode. */
  enterEditMode?: boolean
}

export type PageType = 'pdf' | 'image'
export type TextDirection = 'ltr' | 'rtl' | 'auto'
export type TextAlignment = 'start' | 'end' | 'center'
export type TextVerticalAnchor = 'top' | 'bottom'
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
  /** Returns whether the active page has committed ink; undo, redo, clear, and page changes are reflected. */
  hasInk(): boolean
  enterEditMode(viewport?: ViewportOptions): void
  enterViewMode(viewport?: ViewportOptions): void
  undo(): void
  redo(): void
  clear(): void
  /** Commits text inside a fixed physical page rectangle, clipping to complete visible lines. */
  addTextAnnotation(text: string, bounds: TextAnnotationBounds, options?: TextAnnotationOptions): void
  /**
   * Finds literal source-text matches on the page selected when called,
   * comparing ASCII letters without case and all other characters exactly.
   * Multiword keys match adjacent complete words on one visual row, regardless
   * of extracted word order. The combined label bounds select the writing rule.
   * Skips matches without a usable same-row horizontal rule on the resolved
   * direction's side, then uses the first (default) or last eligible match.
   * Bottom anchoring grows text upward from the rule; top anchoring places it
   * below. The search does not OCR image pages. A missing key rejects with
   * `text_key_not_found`; matches without a usable rule reject with
   * `text_rule_not_found`. Document replacement, target-page deletion, or
   * disposal rejects with `operation_cancelled`.
   */
  insertTextByFieldName(text: string, key: string, options?: TextInsertionByKeyOptions): Promise<void>
  /** Focuses a label's adjacent writing rule; a newer focus or mode request can cancel it. */
  focusPageByFieldName(key: string, options?: FieldFocusOptions): Promise<void>
  /** Sets the base direction for new text; `auto` follows app RTL policy and is saved with each annotation. */
  setTextDirection(direction: TextDirection): void
  /** Arms one-shot text placement; optional width and height bound the box from the tap's top-left. */
  insertAnnotationOn(options?: TextPlacementOptions): void
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
