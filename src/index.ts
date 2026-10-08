import React, { useEffect, useImperativeHandle, useLayoutEffect, useMemo, useState } from 'react';
import { callback, getHostComponent } from 'react-native-nitro-modules';
import InkSignViewConfig from '../nitrogen/generated/shared/json/InkSignViewConfig.json';
import { createViewConnection } from './viewConnection';
import {
  argumentError,
  validateAddPagesOptions,
  validateFieldFocusOptions,
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
  ResolveTextOptions,
  TextEntry,
  TextId,
  TextSelection,
  TextValueSource,
  PagerDirection,
  FieldFocusOptions,
  FieldFocusVerticalAnchor,
  PageInfo,
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
  InkSignViewProps,
  ViewerState,
  InteractionMode,
  InkSignView as InkSignViewNativeHandle,
  AnalyzedPage as AnalyzedPageNativeHandle,
  InkSignViewMethods,
} from './InkSignView.nitro';

export type {
  AnalyzedPage,
  FieldFocusOptions,
  FieldFocusVerticalAnchor,
  PageInfo,
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
  InkSignViewProps,
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

export type InkSignViewHandle = InkSignViewMethods &
  Pick<InkSignViewNativeHandle, '__type' | 'name' | 'toString' | 'equals' | 'dispose'>;

const NativeInkSignView = getHostComponent<InkSignViewProps, InkSignViewMethods>(
  'InkSignView',
  () => InkSignViewConfig,
);

type NativeInkSignViewProps = React.ComponentProps<typeof NativeInkSignView>;
type InkSignViewComponentProps = Omit<
  NativeInkSignViewProps,
  'hybridRef' | 'onStateChange' | 'onPageChange' | 'onTextSelectionChange' | 'onZoomedInChange'
> & {
  onStateChange?: InkSignViewProps['onStateChange'];
  onPageChange?: InkSignViewProps['onPageChange'];
  onZoomedInChange?: InkSignViewProps['onZoomedInChange'];
  onTextSelectionChange?: InkSignViewProps['onTextSelectionChange'];
};

function callAsync<T>(validate: () => void, invoke: () => Promise<T>): Promise<T> {
  try {
    validate();
    return invoke();
  } catch (error) {
    return Promise.reject(error);
  }
}

const nativeHandles = new WeakMap<object, () => InkSignViewNativeHandle>();

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
    clearText(id) {
      validateTextId(id);
      native.clearText(id);
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
        () => validateFieldFocusOptions(options),
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
          if (typeof path !== 'string' || path.trim() === '') {
            throw argumentError('invalid_document_path', 'A non-empty PDF path is required');
          }
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
    setInkMode(viewport) {
      return callAsync(
        () => validateViewportOptions(viewport),
        () => connection.invoke(native => native.setInkMode(viewport)),
      );
    },
    setViewMode(viewport) {
      return callAsync(
        () => validateViewportOptions(viewport),
        () => connection.invoke(native => native.setViewMode(viewport)),
      );
    },
    undo: () => getNative().undo(),
    redo: () => getNative().redo(),
    clear: () => getNative().clear(),
    setTextDirection(direction) {
      if (direction !== 'ltr' && direction !== 'rtl' && direction !== 'auto') {
        throw argumentError('invalid_text_direction', 'Text direction must be ltr, rtl, or auto');
      }
      getNative().setTextDirection(direction);
    },
    setTextMode(options) {
      return callAsync(
        () => validateTextModeOptions(options),
        () => connection.invoke(native => native.setTextMode(options)),
      );
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

export const InkSignView = React.forwardRef<InkSignViewHandle, InkSignViewComponentProps>(
  (props, ref) => {
    validatePagerDirection(props.pagerDirection);
    const { onStateChange, onPageChange, onTextSelectionChange, onZoomedInChange, ...nativeProps } =
      props;
    const [connection] = useState(createViewConnection);
    const [handle] = useState(() => createValidatedHandle(connection));
    useLayoutEffect(() => {
      connection.mount();
    }, []);
    // Suspense disconnects layout effects while retaining the native view.
    useEffect(() => () => connection.unmount(), []);
    useImperativeHandle(ref, () => handle, []);
    const wrappedHybridRef = useMemo(() => callback(connection.attach), []);
    const wrappedStateChange = useMemo(() => callback(onStateChange), [onStateChange]);
    const wrappedPageChange = useMemo(() => callback(onPageChange), [onPageChange]);
    const wrappedZoomedInChange = useMemo(() => callback(onZoomedInChange), [onZoomedInChange]);
    const wrappedTextSelectionChange = useMemo(
      () => callback(onTextSelectionChange),
      [onTextSelectionChange],
    );

    return React.createElement(NativeInkSignView, {
      ...nativeProps,
      hybridRef: wrappedHybridRef,
      onStateChange: wrappedStateChange,
      onPageChange: wrappedPageChange,
      onZoomedInChange: wrappedZoomedInChange,
      onTextSelectionChange: wrappedTextSelectionChange,
    });
  },
);
