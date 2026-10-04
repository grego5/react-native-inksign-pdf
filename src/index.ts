import React, { useCallback, useMemo } from 'react';
import { callback, getHostComponent } from 'react-native-nitro-modules';
import InkSignViewConfig from '../nitrogen/generated/shared/json/InkSignViewConfig.json';
import {
  argumentError,
  validateAddPagesOptions,
  validateTextAnnotationBounds,
  validateTextAnnotationOptions,
  validateTextModeOptions,
  validateViewportOptions,
} from './publicArguments';
import { createFieldFocusCommand, createTextKeyInsertionCommand } from './textKeyInsertion';

import type {
  FieldFocusOptions,
  PageInfo,
  TextAnnotationBounds,
  TextAnnotationOptions,
  TextInsertionByKeyOptions,
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
  InkSignViewMethods,
} from './InkSignView.nitro';

export type {
  FieldFocusOptions,
  PageInfo,
  TextAnnotationBounds,
  TextAnnotationOptions,
  TextInsertionByKeyOptions,
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
  InkSignViewMethods,
};

export type InkSignViewHandle = InkSignViewMethods &
  Pick<InkSignViewNativeHandle, '__type' | 'name' | 'toString' | 'equals' | 'dispose'>;

const NativeInkSignView = getHostComponent<InkSignViewProps, InkSignViewMethods>(
  'InkSignView',
  () => InkSignViewConfig,
);

type NativeInkSignViewProps = React.ComponentProps<typeof NativeInkSignView>;
type InkSignViewComponentProps = Omit<NativeInkSignViewProps, 'hybridRef' | 'onStateChange' | 'onPageChange'> & {
  onStateChange?: InkSignViewProps['onStateChange'];
  onPageChange?: InkSignViewProps['onPageChange'];
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
    nextPage: () => native.nextPage(),
    previousPage: () => native.previousPage(),
    getViewport: () => native.getViewport(),
    hasInk: () => native.hasInk(),
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
    addTextAnnotation(text, bounds, options) {
      if (typeof text !== 'string' || text.trim() === '') {
        throw argumentError('invalid_text', 'Text must not be empty');
      }
      validateTextAnnotationBounds(bounds);
      validateTextAnnotationOptions(options);
      native.addTextAnnotation(text, bounds, options);
    },
    insertTextByFieldName: createTextKeyInsertionCommand(
      (text, key, options) => native.insertTextByFieldName(text, key, options),
    ),
    focusPageByFieldName: createFieldFocusCommand(
      (key, options) => native.focusPageByFieldName(key, options),
    ),
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
    increaseTextSize: () => native.increaseTextSize(),
    decreaseTextSize: () => native.decreaseTextSize(),
    removeTextAnnotation: () => native.removeTextAnnotation(),
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
    const { onStateChange, onPageChange, ...nativeProps } = props;
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

    return React.createElement(NativeInkSignView, {
      ...nativeProps,
      hybridRef: wrappedHybridRef,
      onStateChange: wrappedStateChange,
      onPageChange: wrappedPageChange,
    });
  },
);
