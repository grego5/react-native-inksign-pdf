import type {
  HybridObject,
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

import type { InkSignDocument, DocumentPage } from './InkSignDocument.nitro'
import type {
  StrokeColor,
  TextColor,
  PageChangeEvent,
  TextAnnotationOptions,
  TextModeOptions,
  InputTargetFocusOptions,
  InputTargetId,
  PagerDirection,
  TextSelection,
  PageCoords,
  TextDirection,
  InputMode,
  PageQuery,
  ViewerState,
  ViewportOptions,
  Viewport,
  DoubleTapOptions,
} from './InkSignTypes'

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
  getPage(pageIndex?: PageQuery): Promise<DocumentPage>
  focusInputTarget(page: DocumentPage, id: InputTargetId, options?: InputTargetFocusOptions): Promise<void>
  /** Temporarily picks one page tap, then restores this session's input mode. */
  requestUserTap(): Promise<PageCoords>
  /** Preserves the viewport when omitted; an empty object fits the current page. */
  setViewport(options?: ViewportOptions): Promise<void>
}

export interface InkSignViewProps extends HybridViewProps {
  /** Externally owned document. Removing it or unmounting detaches presentation only. */
  document?: InkSignDocument

  strokeColor?: StrokeColor
  /** Android brush minimum in logical display points; PencilKit controls iOS dynamics. */
  strokeMinWidth?: number
  /** Logical display-point width for new strokes (default 4). iOS uses PencilKit's nominal width, not a pressure cap. */
  strokeMaxWidth?: number
  /** Android brush smoothing; iOS uses PencilKit smoothing. */
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
  /** Default writing direction; omission/auto follows app layout. Updates the active editor without moving its bounds. */
  textDirection?: TextDirection
  onStateChange?: (event: ViewerState) => void
  /** Active-page metadata after navigation or committed edits; deduplicated. */
  onPageChange?: (event: PageChangeEvent) => void
  /** Settled zoom relative to page fit: 1 is fitted, below 1 is zoomed out. */
  onZoomChange?: (zoom: number) => void
  onTextSelectionChange?: (selection: TextSelection | null) => void
}

export interface InkSignViewMethods extends HybridViewMethods {
  /** Selects the next page; stays on the last page at the end. */
  nextPage(): void
  focusInputTarget(page: DocumentPage, id: InputTargetId, options?: InputTargetFocusOptions): Promise<void>
  /** Selects the previous page; stays on the first page at the beginning. */
  previousPage(): void
  /** Returns the active page's current focus coordinates and zoom. */
  getViewport(): Viewport
  /** Enters pageCoords mode on the active page without changing the viewport. One tap resolves and returns to view mode; page/mode changes or teardown cancel it. */
  requestUserTap(): Promise<PageCoords>
  /** Reads native selection synchronously; null when no text is selected. Handle operations reject after document/page/target invalidation. */
  getSelectedText(): TextHandle | null
  /** Synchronously enters a mode, preserves the viewport, and supersedes the previous session. Requires a ready document. Options apply only to text placement; their viewport changes wait for a valid tap. */
  setMode(mode: InputMode, options?: TextModeOptions): ModeSession
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
