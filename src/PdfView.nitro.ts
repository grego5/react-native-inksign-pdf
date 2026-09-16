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

export interface PdfViewProps extends HybridViewProps {
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

export interface PdfViewMethods extends HybridViewMethods {
  open(path: string, options?: ViewportOptions): Promise<PageInfo>
  nextPage(): Promise<PageInfo>
  previousPage(): Promise<PageInfo>
  getViewport(): Promise<Viewport>
  enterEditMode(viewport?: ViewportOptions): Promise<void>
  enterViewMode(viewport?: ViewportOptions): Promise<void>
  undo(): void
  redo(): void
  clear(): void
  /** Arms one-shot native text placement at the next valid page tap. */
  insertAnnotationOn(): Promise<void>
  /** Cancels a pending one-shot text placement, if any. */
  insertAnnotationOff(): Promise<void>
  increaseTextSize(): Promise<number>
  decreaseTextSize(): Promise<number>
  removeTextAnnotation(): Promise<void>
  finalize(): Promise<string>
  /** Android debug builds only. Clears the bounded native trace and starts recording. */
  startDebugRecording(): void
  /** Android debug builds only. Stops accepting trace operations. */
  stopDebugRecording(): void
  /** Android debug builds only. Writes the stopped trace as replayable CSV. */
  exportDebugRecording(): Promise<string>
}

export type PdfView = HybridView<
  PdfViewProps,
  PdfViewMethods
>
