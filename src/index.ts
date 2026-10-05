import React, { useCallback, useMemo } from 'react';
import { callback, getHostComponent } from 'react-native-nitro-modules';
import InkSignViewConfig from '../nitrogen/generated/shared/json/InkSignViewConfig.json';
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
  StateChangeEvent,
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
  StateChangeEvent,
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
type InkSignViewComponentProps = Omit<NativeInkSignViewProps, 'hybridRef' | 'onStateChange' | 'onPageChange' | 'onTextSelectionChange'> & {
  onStateChange?: InkSignViewProps['onStateChange'];
  onPageChange?: InkSignViewProps['onPageChange'];
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

const nativeHandles = new WeakMap<object, InkSignViewNativeHandle>();

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
      if (options === undefined) throw argumentError('invalid_text_options', 'Text options are required');
      validateTextAnnotationOptions(options);
      native.setTextOptions(id, options);
    },
    getTextEntry(id) {
      validateTextId(id);
      return native.getTextEntry(id);
    },
    adjustTextSize(id, delta) {
      validateTextId(id);
      if (!Number.isFinite(delta)) throw argumentError('invalid_text_size_delta', 'Text size delta must be finite');
      return native.adjustTextSize(id, delta);
    },
    getTextEntries: () => native.getTextEntries(),
    focusText(id, options) {
      validateTextId(id);
      return callAsync(() => validateFieldFocusOptions(options), () => native.focusText(id, options));
    },
  };
}

function createValidatedHandle(native: InkSignViewNativeHandle): InkSignViewHandle {
  const handle = {
    __type: native.__type,
    name: native.name,
    toString: () => native.toString(),
    equals(other: InkSignViewNativeHandle) {
      return native.equals(nativeHandles.get(other) ?? other);
    },
    dispose: () => native.dispose(),
    open(path, viewport) {
      return callAsync(() => {
        if (typeof path !== 'string' || path.trim() === '') {
          throw argumentError('invalid_document_path', 'A non-empty PDF path is required');
        }
        validateViewportOptions(viewport);
      }, () => native.open(path, viewport));
    },
    addPages(options) {
      return callAsync(() => validateAddPagesOptions(options), () => native.addPages(options));
    },
    removePage: () => callAsync(() => {}, () => native.removePage()),
    movePage(pageIndex) {
      return callAsync(() => {
        if (typeof pageIndex !== 'number' || !Number.isInteger(pageIndex) || pageIndex < 0) {
          throw argumentError('invalid_page_index', 'The destination page index must be a non-negative integer');
        }
      }, () => native.movePage(pageIndex));
    },
    rotatePage(degrees) {
      return callAsync(() => {
        if (degrees !== 90 && degrees !== 180 && degrees !== 270) {
          throw argumentError('invalid_page_rotation', 'Page rotation must be 90, 180, or 270 degrees clockwise');
        }
      }, () => native.rotatePage(degrees));
    },
    nextPage: () => native.nextPage(),
    previousPage: () => native.previousPage(),
    getViewport: () => native.getViewport(),
    hasInk: () => native.hasInk(),
    getPage(pageIndex) {
      return callAsync(() => validatePageIndex(pageIndex), async () =>
        createValidatedAnalyzedPage(await native.getPage(pageIndex)));
    },
    setInkMode(viewport) {
      validateViewportOptions(viewport);
      native.setInkMode(viewport);
    },
    setViewMode(viewport) {
      validateViewportOptions(viewport);
      native.setViewMode(viewport);
    },
    undo: () => native.undo(),
    redo: () => native.redo(),
    clear: () => native.clear(),
    setTextDirection(direction) {
      if (direction !== 'ltr' && direction !== 'rtl' && direction !== 'auto') {
        throw argumentError('invalid_text_direction', 'Text direction must be ltr, rtl, or auto');
      }
      native.setTextDirection(direction);
    },
    setTextMode(options) {
      validateTextModeOptions(options);
      native.setTextMode(options);
    },
    finalize: () => callAsync(() => {}, () => native.finalize()),
    startDebugRecording: () => native.startDebugRecording(),
    stopDebugRecording: () => native.stopDebugRecording(),
    exportDebugRecording: () => callAsync(() => {}, () => native.exportDebugRecording()),
  } satisfies InkSignViewHandle;
  nativeHandles.set(handle, native);
  return handle;
}

export const InkSignView = React.forwardRef<InkSignViewHandle, InkSignViewComponentProps>(
  (props, ref) => {
    validatePagerDirection(props.pagerDirection);
    const { onStateChange, onPageChange, onTextSelectionChange, ...nativeProps } = props;
    const wrappedHybridRef = useMemo(
      () =>
        callback((value: InkSignViewNativeHandle | null) => {
          const handle = value === null ? null : createValidatedHandle(value);
          if (typeof ref === 'function') {
            ref(handle);
          } else if (ref !== null) {
            ref.current = handle;
          }
        }),
      [ref],
    );
    const wrappedStateChange = useMemo(() => callback(onStateChange), [onStateChange]);
    const wrappedPageChange = useMemo(() => callback(onPageChange), [onPageChange]);
    const wrappedTextSelectionChange = useMemo(() => callback(onTextSelectionChange), [onTextSelectionChange]);

    return React.createElement(NativeInkSignView, {
      ...nativeProps,
      hybridRef: wrappedHybridRef,
      onStateChange: wrappedStateChange,
      onPageChange: wrappedPageChange,
      onTextSelectionChange: wrappedTextSelectionChange,
    });
  },
);
