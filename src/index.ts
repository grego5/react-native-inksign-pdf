import React, { useEffect, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { callback, getHostComponent } from 'react-native-nitro-modules';
import InkSignViewConfig from '../nitrogen/generated/shared/json/InkSignViewConfig.json';
import { createViewConnection } from './viewConnection';
import {
  argumentError,
  validateAddPagesOptions,
  validateTextFocusOptions,
  validatePageIndex,
  validatePagerDirection,
  validateResolveTextOptions,
  validateTextId,
  validateTextAnnotationOptions,
  validateTextModeOptions,
  validateViewportOptions,
} from './publicArguments';
import type {
  AnalyzedPage,
  ModeSession,
  InputMode,
  ResolveTextOptions,
  TextEntry,
  TextId,
  TextSelection,
  TextValueSource,
  PagerDirection,
  TextFocusOptions,
  FieldFocusVerticalAnchor,
  PageInfo,
  PageCoords,
  TextAnnotationBounds,
  TextAnnotationOptions,
  TextKeyOccurrence,
  TextModeOptions,
  PageType,
  TextDirection,
  TextAlignment,
  TextVerticalAnchor,
  AddPagesActivePage,
  AddPagesOptions,
  AddPagesResult,
  ImagePageSize,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  AndroidFallbackFont,
  InkSignViewProps as InkSignViewNativeProps,
  ViewerState,
  InteractionMode,
  InkSignView as InkSignViewNativeHandle,
  AnalyzedPage as AnalyzedPageNativeHandle,
  InkSignViewMethods,
} from './InkSignView.nitro';

export type {
  AnalyzedPage,
  ModeSession,
  InputMode,
  TextFocusOptions,
  FieldFocusVerticalAnchor,
  PageInfo,
  PageCoords,
  TextAnnotationBounds,
  TextAnnotationOptions,
  TextKeyOccurrence,
  TextModeOptions,
  PageType,
  TextDirection,
  TextAlignment,
  TextVerticalAnchor,
  AddPagesActivePage,
  AddPagesOptions,
  AddPagesResult,
  ImagePageSize,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  AndroidFallbackFont,
  ViewerState,
  InteractionMode,
  ResolveTextOptions,
  TextEntry,
  TextId,
  TextSelection,
  TextValueSource,
  PagerDirection,
  InkSignViewMethods,
};

export type InkSignViewHandle = Omit<InkSignViewMethods, 'setMode'> & {
  setMode(mode: 'view' | 'ink'): ModeSession;
  setMode(mode: 'text', options?: TextModeOptions): ModeSession;
} &
  Pick<InkSignViewNativeHandle, '__type' | 'name' | 'toString' | 'equals' | 'dispose'>;

const NativeInkSignView = getHostComponent<InkSignViewNativeProps, InkSignViewMethods>(
  'InkSignView',
  () => InkSignViewConfig,
);

type NativeInkSignViewProps = React.ComponentProps<typeof NativeInkSignView>;
export type InkSignViewProps = Omit<
  NativeInkSignViewProps,
  'hybridRef' | 'onStateChange' | 'onPageChange' | 'onTextSelectionChange' | 'onZoomChange'
> & {
  /** Local PDF or JPEG path/file:// URI. JPEG becomes one contain-fitted A4 page. */
  initialDocument?: string;
  onStateChange?: InkSignViewNativeProps['onStateChange'];
  onPageChange?: InkSignViewNativeProps['onPageChange'];
  onZoomChange?: InkSignViewNativeProps['onZoomChange'];
  onTextSelectionChange?: InkSignViewNativeProps['onTextSelectionChange'];
};

function validateDocumentPath(path: string): void {
  if (typeof path !== 'string' || path.trim() === '') {
    throw argumentError('invalid_document_path', 'A non-empty PDF path or file URI is required');
  }
}

function callAsync<T>(validate: () => void, invoke: () => Promise<T>): Promise<T> {
  try {
    validate();
    return invoke();
  } catch (error) {
    return Promise.reject(error);
  }
}

const nativeHandles = new WeakMap<object, () => InkSignViewNativeHandle>();

/** Expected cancellation of a superseded mode or document operation. */
export function isOperationCancelled(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const failure = error as { code?: unknown; message?: unknown };
  return failure.code === 'operation_cancelled' ||
    (typeof failure.message === 'string' && /\boperation_cancelled\b/.test(failure.message));
}

function createValidatedModeSession(native: ModeSession): ModeSession {
  return {
    __type: native.__type,
    name: native.name,
    toString: () => native.toString(),
    equals: other => native.equals(other),
    dispose: () => native.dispose(),
    getPage(pageIndex) {
      return callAsync(() => validatePageIndex(pageIndex), async () =>
        createValidatedAnalyzedPage(await native.getPage(pageIndex)));
    },
    requestPageCoords: () => native.requestPageCoords(),
    setViewport(options) {
      return callAsync(() => validateViewportOptions(options), () => native.setViewport(options));
    },
  };
}

function createValidatedAnalyzedPage(native: AnalyzedPageNativeHandle): AnalyzedPage {
  return {
    __type: native.__type,
    name: native.name,
    toString: () => native.toString(),
    equals: (other) => native.equals(other),
    dispose: () => native.dispose(),
    resolveText(options) {
      validateResolveTextOptions(options);
      return native.resolveText(options);
    },
    getTextValue(id) {
      validateTextId(id);
      return native.getTextValue(id);
    },
    setTextValue(id, text) {
      validateTextId(id);
      if (typeof text !== 'string') throw argumentError('invalid_text', 'Text must be a string');
      native.setTextValue(id, text);
    },
    setTextOptions(id, options) {
      validateTextId(id);
      if (options === undefined)
        throw argumentError('invalid_text_options', 'Text options are required');
      validateTextAnnotationOptions(options);
      native.setTextOptions(id, options);
    },
    getTextEntry(id) {
      validateTextId(id);
      return native.getTextEntry(id);
    },
    adjustTextSize(id, delta) {
      validateTextId(id);
      if (!Number.isFinite(delta))
        throw argumentError('invalid_text_size_delta', 'Text size delta must be finite');
      return native.adjustTextSize(id, delta);
    },
    getTextEntries: () => native.getTextEntries(),
    focusText(id, options) {
      validateTextId(id);
      return callAsync(
        () => validateTextFocusOptions(options),
        () => native.focusText(id, options),
      );
    },
  };
}

function createValidatedHandle(
  connection: ReturnType<typeof createViewConnection>,
): InkSignViewHandle {
  const getNative = connection.getNative;
  const handle = {
    get __type() {
      return getNative().__type;
    },
    get name() {
      return getNative().name;
    },
    toString: () => getNative().toString(),
    equals(other: InkSignViewNativeHandle) {
      return getNative().equals(nativeHandles.get(other)?.() ?? other);
    },
    dispose: () => getNative().dispose(),
    open(path, viewport) {
      return callAsync(
        () => {
          validateDocumentPath(path);
          validateViewportOptions(viewport);
        },
        () => connection.invoke(native => native.open(path, viewport)),
      );
    },
    close(cancelPending) {
      return callAsync(() => {
        if (cancelPending !== undefined && typeof cancelPending !== 'boolean') {
          throw argumentError('invalid_close_options', 'Cancellation must be a boolean');
        }
      }, () => connection.invoke(native => native.close(cancelPending), cancelPending === true));
    },
    requestPageCoords: () => connection.invoke(native => native.requestPageCoords()),
    addPages(options) {
      return callAsync(
        () => validateAddPagesOptions(options),
        () => connection.invoke(native => native.addPages(options)),
      );
    },
    removePage: () =>
      callAsync(
        () => {},
        () => connection.invoke(native => native.removePage()),
      ),
    movePage(pageIndex) {
      return callAsync(
        () => {
          if (typeof pageIndex !== 'number' || !Number.isInteger(pageIndex) || pageIndex < 0) {
            throw argumentError(
              'invalid_page_index',
              'The destination page index must be a non-negative integer',
            );
          }
        },
        () => connection.invoke(native => native.movePage(pageIndex)),
      );
    },
    rotatePage(degrees) {
      return callAsync(
        () => {
          if (degrees !== 90 && degrees !== 180 && degrees !== 270) {
            throw argumentError(
              'invalid_page_rotation',
              'Page rotation must be 90, 180, or 270 degrees clockwise',
            );
          }
        },
        () => connection.invoke(native => native.rotatePage(degrees)),
      );
    },
    nextPage: () => getNative().nextPage(),
    previousPage: () => getNative().previousPage(),
    getViewport: () => getNative().getViewport(),
    hasInk: () => getNative().hasInk(),
    getPage(pageIndex) {
      return callAsync(
        () => validatePageIndex(pageIndex),
        async () => createValidatedAnalyzedPage(await connection.invoke(native => native.getPage(pageIndex))),
      );
    },
    setMode(mode: InputMode, options?: TextModeOptions) {
      if (mode !== 'view' && mode !== 'ink' && mode !== 'text') {
        throw argumentError('invalid_input_mode', 'Mode must be view, ink, or text');
      }
      if (mode !== 'text' && options !== undefined) {
        throw argumentError('invalid_mode_options', 'Placement options apply only to text mode');
      }
      if (mode === 'text') validateTextModeOptions(options);
      return createValidatedModeSession(getNative().setMode(mode, options));
    },
    undo: () => getNative().undo(),
    redo: () => getNative().redo(),
    clear: () => getNative().clear(),
    clearInk: () => getNative().clearInk(),
    setTextDirection(direction) {
      if (direction !== 'ltr' && direction !== 'rtl' && direction !== 'auto') {
        throw argumentError('invalid_text_direction', 'Text direction must be ltr, rtl, or auto');
      }
      getNative().setTextDirection(direction);
    },
    finalize: () =>
      callAsync(
        () => {},
        () => connection.invoke(native => native.finalize()),
      ),
    startDebugRecording: () => getNative().startDebugRecording(),
    stopDebugRecording: () => getNative().stopDebugRecording(),
    exportDebugRecording: () =>
      callAsync(
        () => {},
        () => connection.invoke(native => native.exportDebugRecording()),
      ),
  } satisfies InkSignViewHandle;
  nativeHandles.set(handle, getNative);
  return handle;
}

export const InkSignView = React.forwardRef<InkSignViewHandle, InkSignViewProps>(
  (props, ref) => {
    validatePagerDirection(props.pagerDirection);
    const {
      initialDocument,
      onStateChange,
      onPageChange,
      onTextSelectionChange,
      onZoomChange,
      ...nativeProps
    } = props;
    const callbacks = useRef({
      onStateChange,
      onPageChange,
      onTextSelectionChange,
      onZoomChange,
    });
    useLayoutEffect(() => {
      callbacks.current = { onStateChange, onPageChange, onTextSelectionChange, onZoomChange };
    });
    const [nativeCallbacks] = useState(() => ({
      onStateChange: callback((event: ViewerState) => callbacks.current.onStateChange?.(event)),
      onPageChange: callback((event: PageInfo) => callbacks.current.onPageChange?.(event)),
      onTextSelectionChange: callback((selection: TextSelection | null) =>
        callbacks.current.onTextSelectionChange?.(selection)),
      onZoomChange: callback((zoom: number) =>
        callbacks.current.onZoomChange?.(zoom)),
    }));
    const [connection] = useState(createViewConnection);
    const [handle] = useState(() => createValidatedHandle(connection));
    useLayoutEffect(() => {
      if (initialDocument !== undefined) validateDocumentPath(initialDocument);
      connection.mount(
        initialDocument === undefined ? undefined : () => handle.open(initialDocument),
      );
    }, [initialDocument]);
    // Suspense disconnects layout effects while retaining the native view.
    useEffect(() => () => connection.unmount(), []);
    useImperativeHandle(ref, () => handle, []);
    const wrappedHybridRef = useMemo(() => callback(connection.attach), []);

    return React.createElement(NativeInkSignView, {
      ...nativeProps,
      hybridRef: wrappedHybridRef,
      onStateChange: onStateChange ? nativeCallbacks.onStateChange : undefined,
      onPageChange: onPageChange ? nativeCallbacks.onPageChange : undefined,
      onZoomChange: onZoomChange ? nativeCallbacks.onZoomChange : undefined,
      onTextSelectionChange: onTextSelectionChange ? nativeCallbacks.onTextSelectionChange : undefined,
    });
  },
);
