import React, { useCallback, useMemo } from 'react';
import { callback, getHostComponent } from 'react-native-nitro-modules';
import InkSignViewConfig from '../nitrogen/generated/shared/json/InkSignViewConfig.json';

import type {
  PageInfo,
  PageType,
  TextDirection,
  AddPagesOptions,
  AddPagesResult,
  ImagePageSize,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  PdfFallbackFont,
  InkSignViewProps,
  StateChangeEvent,
  InteractionMode,
  InkSignView as InkSignViewNativeHandle,
  InkSignViewMethods,
} from './InkSignView.nitro';

export type {
  PageInfo,
  PageType,
  TextDirection,
  AddPagesOptions,
  AddPagesResult,
  ImagePageSize,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  PdfFallbackFont,
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function argumentError(code: string, message: string): Error {
  return new Error(`${code}: ${message}`);
}

function validateViewportOptions(value: unknown): void {
  if (value === undefined || value === null) return;
  if (!isRecord(value)) {
    throw argumentError('invalid_viewport', 'Viewport options must be an object');
  }
  const hasX = value.x !== undefined;
  const hasY = value.y !== undefined;
  if (hasX !== hasY) {
    throw argumentError('invalid_viewport', 'Viewport x and y must be supplied together');
  }
  const coordinateKeys: ReadonlyArray<'x' | 'y'> = ['x', 'y'];
  for (const key of coordinateKeys) {
    const coordinate = value[key];
    if (coordinate !== undefined && (typeof coordinate !== 'number' || !Number.isFinite(coordinate))) {
      throw argumentError('invalid_viewport', `Viewport ${key} must be finite`);
    }
  }
  const zoom = value.zoom;
  if (zoom !== undefined &&
    (typeof zoom !== 'number' || !Number.isFinite(zoom) || zoom <= 0)) {
    throw argumentError('invalid_viewport', 'Viewport zoom must be finite and positive');
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
      return callAsync(() => {
        if (options === undefined || options === null) return;
        if (!isRecord(options)) {
          throw argumentError('invalid_page_options', 'Page options must be an object');
        }
        if (options.type !== undefined && options.type !== 'pdf' && options.type !== 'image') {
          throw argumentError('invalid_page_type', 'Page type must be pdf or image');
        }
        const sources = options.sources;
        if (sources !== undefined && (!Array.isArray(sources) ||
          !sources.every((source) => typeof source === 'string' && source.trim() !== ''))) {
          throw argumentError('invalid_page_sources', 'Page sources must be non-empty paths');
        }
        const imageSize = options.imagePageSize;
        if (imageSize !== undefined && imageSize !== null &&
          (!isRecord(imageSize) ||
            typeof imageSize.width !== 'number' || !Number.isFinite(imageSize.width) || imageSize.width <= 0 ||
            typeof imageSize.height !== 'number' || !Number.isFinite(imageSize.height) || imageSize.height <= 0)) {
          throw argumentError('invalid_image_page_size', 'Image page dimensions must be finite positive PDF points');
        }
      }, () => native.addPages(options));
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
    enterEditMode(viewport) {
      validateViewportOptions(viewport);
      native.enterEditMode(viewport);
    },
    enterViewMode(viewport) {
      validateViewportOptions(viewport);
      native.enterViewMode(viewport);
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
    insertAnnotationOn: () => native.insertAnnotationOn(),
    insertAnnotationOff: () => native.insertAnnotationOff(),
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
