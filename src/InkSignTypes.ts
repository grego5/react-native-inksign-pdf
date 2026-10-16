/** Shared document, page, text, and viewer data contracts. */

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

export type TextDirection = 'ltr' | 'rtl' | 'auto'

export type InputMode = 'view' | 'ink' | 'text'

export type TextAlignment = 'start' | 'end' | 'center'

export type TextVerticalAnchor = 'top' | 'bottom'

export type FieldFocusVerticalAnchor = 'top' | 'bottom' | 'center'

export type TextKeyOccurrence = 'first' | 'last'

export interface TaggedPageQuery {
  tag: string
  /** Zero-based position among matching pages in current document order. Defaults to 0. */
  index?: number
}

export type PageQuery = number | TaggedPageQuery

/** Accepted input content, checked natively for explicit and selected sources. */
export type PageInputType = 'pdf' | 'image'

/** Image page dimensions in PDF points. */
export interface ImagePageSize {
  width: number
  height: number
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
