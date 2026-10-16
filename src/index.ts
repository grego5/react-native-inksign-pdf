import { Platform } from 'react-native';
import React, { useEffect, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { callback, getHostComponent, NitroModules } from 'react-native-nitro-modules';
import InkSignViewConfig from '../nitrogen/generated/shared/json/InkSignViewConfig.json';
import { createViewConnection } from './viewConnection';
import {
  argumentError,
  validateAddPagesOptions,
  validateInputTargetFocusOptions,
  validatePageIndex,
  validatePageQuery,
  validatePageTag,
  validatePagerDirection,
  validateResolveInputUnderlineOptions,
  validateCreateInputAreaOptions,
  validateInputTargetId,
  validateTextAnnotationOptions,
  validateTextModeOptions,
  validateViewportOptions,
} from './publicArguments';
import type {
  DocumentState,
  PageTextMethods,
  InputMode,
  ResolveInputUnderlineOptions,
  CreateInputAreaOptions,
  InputTarget,
  InputTargetId,
  TextSelection,
  TextValueSource,
  PagerDirection,
  InputTargetFocusOptions,
  FieldFocusVerticalAnchor,
  PageInfo,
  PageQuery,
  TaggedPageQuery,
  PageChangeEvent,
  PageCoords,
  TextAnnotationBounds,
  TextAnnotationOptions,
  TextPresentationOptions,
  TextKeyOccurrence,
  TextModeOptions,
  TextDirection,
  TextAlignment,
  TextVerticalAnchor,
  ImagePageSize,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  AndroidFallbackFont,
  ViewerState,
  InteractionMode,
} from './InkSignTypes';
import type {
  ModeSession,
  TextHandle,
  InkSignViewProps as InkSignViewNativeProps,
  InkSignView as InkSignViewNativeHandle,
  InkSignViewMethods,
} from './InkSignView.nitro';
import type { NamedFontSource, DocumentOpenOptions, DocumentAddPagesOptions, DocumentAddPagesResult, DocumentPage, InkSignDocument, InkSignDocumentFactory } from './InkSignDocument.nitro';
export type { NamedFontSource, DocumentOpenOptions, DocumentAddPagesOptions, DocumentAddPagesResult, DocumentPage, InkSignDocument } from './InkSignDocument.nitro';

export type {
  DocumentState,
  ModeSession,
  InputMode,
  InputTargetFocusOptions,
  FieldFocusVerticalAnchor,
  PageInfo,
  PageQuery,
  TaggedPageQuery,
  PageChangeEvent,
  PageCoords,
  TextAnnotationBounds,
  TextAnnotationOptions,
  TextPresentationOptions,
  TextKeyOccurrence,
  TextModeOptions,
  TextDirection,
  TextAlignment,
  TextVerticalAnchor,
  ImagePageSize,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  AndroidFallbackFont,
  ViewerState,
  InteractionMode,
  ResolveInputUnderlineOptions,
  CreateInputAreaOptions,
  InputTarget,
  InputTargetId,
  TextSelection,
  TextHandle,
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
  'document' | 'hybridRef' | 'onStateChange' | 'onPageChange' | 'onTextSelectionChange' | 'onZoomChange'
> & {
  /** Initialized document owner; render the viewer after openDoc resolves. */
  document: InkSignDocument;
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
      return callAsync(() => validatePageQuery(pageIndex), async () =>
        createValidatedDocumentPage(await native.getPage(pageIndex)));
    },
    requestUserTap: () => native.requestUserTap(),
    focusInputTarget(page, id, options) {
      return callAsync(() => validateInputTargetFocusOptions(options), () =>
        native.focusInputTarget(nativePages.get(page) ?? page, id, options));
    },
    setViewport(options) {
      return callAsync(() => validateViewportOptions(options), () => native.setViewport(options));
    },
  };
}

function createValidatedTextHandle(native: TextHandle): TextHandle {
  return {
    __type: native.__type,
    name: native.name,
    toString: () => native.toString(),
    equals: other => native.equals(other),
    dispose: () => native.dispose(),
    getValue: () => native.getValue(),
    setValue(text, options) {
      if (typeof text !== 'string') throw argumentError('invalid_text', 'Text must be a string');
      validateTextAnnotationOptions(options);
      native.setValue(text, options);
    },
    setOptions(options) {
      if (options === undefined)
        throw argumentError('invalid_text_options', 'Text options are required');
      validateTextAnnotationOptions(options);
      native.setOptions(options);
    },
    adjustSize(delta) {
      if (!Number.isFinite(delta))
        throw argumentError('invalid_text_size_delta', 'Text size delta must be finite');
      return native.adjustSize(delta);
    },
  };
}

function createValidatedPageText(native: PageTextMethods): PageTextMethods {
  return {
    resolveInputUnderline(options) {
      validateResolveInputUnderlineOptions(options);
      return native.resolveInputUnderline(options);
    },
    createInputArea(options) {
      validateCreateInputAreaOptions(options);
      return native.createInputArea(options);
    },
    getTextValue(id) {
      validateInputTargetId(id);
      return native.getTextValue(id);
    },
    setTextValue(id, text, options) {
      validateInputTargetId(id);
      if (typeof text !== 'string') throw argumentError('invalid_text', 'Text must be a string');
      validateTextAnnotationOptions(options);
      native.setTextValue(id, text, options);
    },
    setTextOptions(id, options) {
      validateInputTargetId(id);
      if (options === undefined)
        throw argumentError('invalid_text_options', 'Text options are required');
      validateTextAnnotationOptions(options);
      native.setTextOptions(id, options);
    },
    getInputTarget(id) {
      validateInputTargetId(id);
      return native.getInputTarget(id);
    },
    adjustTextSize(id, delta) {
      validateInputTargetId(id);
      if (!Number.isFinite(delta))
        throw argumentError('invalid_text_size_delta', 'Text size delta must be finite');
      return native.adjustTextSize(id, delta);
    },
    getInputTargets: () => native.getInputTargets(),
  };
}

function createValidatedViewHandle(
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
    requestUserTap: () => connection.invoke(native => native.requestUserTap()),
    nextPage: () => getNative().nextPage(),
    focusInputTarget(page, id, options) {
      return callAsync(() => validateInputTargetFocusOptions(options), () =>
        connection.invoke(native => native.focusInputTarget(nativePages.get(page) ?? page, id, options)));
    },
    previousPage: () => getNative().previousPage(),
    getViewport: () => getNative().getViewport(),
    getSelectedText() {
      const text = getNative().getSelectedText();
      return text === null ? null : createValidatedTextHandle(text);
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
    if (props.textDirection !== undefined && props.textDirection !== 'auto' &&
        props.textDirection !== 'ltr' && props.textDirection !== 'rtl') {
      throw argumentError('invalid_text_direction', 'Text direction must be ltr, rtl, or auto');
    }
    const {
      document,
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
      onPageChange: callback((event: PageChangeEvent) => callbacks.current.onPageChange?.(event)),
      onTextSelectionChange: callback((selection: TextSelection | null) =>
        callbacks.current.onTextSelectionChange?.(selection)),
      onZoomChange: callback((zoom: number) =>
        callbacks.current.onZoomChange?.(zoom)),
    }));
    const [connection] = useState(createViewConnection);
    const [handle] = useState(() => createValidatedViewHandle(connection));
    useLayoutEffect(() => {
      connection.mount();
    }, []);
    // Suspense disconnects layout effects while retaining the native view.
    useEffect(() => () => connection.unmount(), []);
    useImperativeHandle(ref, () => handle, []);
    const wrappedHybridRef = useMemo(() => callback(connection.attach), []);

    return React.createElement(NativeInkSignView, {
      ...nativeProps,
      document: nativeDocuments.get(document) ?? document,
      hybridRef: wrappedHybridRef,
      onStateChange: onStateChange ? nativeCallbacks.onStateChange : undefined,
      onPageChange: onPageChange ? nativeCallbacks.onPageChange : undefined,
      onZoomChange: onZoomChange ? nativeCallbacks.onZoomChange : undefined,
      onTextSelectionChange: onTextSelectionChange ? nativeCallbacks.onTextSelectionChange : undefined,
    });
  },
);

function validateNamedFonts(fonts: NamedFontSource[]): void {
  if (!Array.isArray(fonts) || fonts.some(font => typeof font !== 'object' || font === null ||
    typeof font.name !== 'string' || font.name.trim() === '' || typeof font.uri !== 'string' || font.uri.trim() === '')) {
    throw argumentError('invalid_font', 'Fonts must be an array of nonempty names and local URIs');
  }
}

function validateRequiredPageIndex(index: number): void {
  if (index === undefined) throw argumentError('invalid_page_index', 'A page index is required');
  validatePageIndex(index);
}

function createValidatedDocumentPage(native: DocumentPage): DocumentPage {
  const handle: DocumentPage = {
    __type: native.__type, name: native.name,
    toString: () => native.toString(), equals: other => native.equals(other), dispose: () => native.dispose(),
    getState: () => native.getState(),
    undo: () => native.undo(),
    redo: () => native.redo(),
    clear: () => native.clear(),
    clearInk: () => native.clearInk(),
    ...createValidatedPageText(native),
  };
  nativePages.set(handle, native);
  return handle;
}

const nativePages = new WeakMap<DocumentPage, DocumentPage>();
const nativeDocuments = new WeakMap<InkSignDocument, InkSignDocument>();

function createValidatedDocument(native: InkSignDocument): InkSignDocument {
  const handle: InkSignDocument = {
    __type: native.__type, name: native.name,
    toString: () => native.toString(), equals: other => native.equals(nativeDocuments.get(other as InkSignDocument) ?? other), dispose: () => native.dispose(),
    get pageCount() { return native.getState().pageCount; },
    getState: () => native.getState(),
    getPage(index) {
      return callAsync(() => validatePageQuery(index, true), async () => createValidatedDocumentPage(await native.getPage(index)));
    },
    getPageIdsByTag(tag) {
      validatePageTag(tag);
      return native.getPageIdsByTag(tag);
    },
    loadFonts(fonts) { return callAsync(() => validateNamedFonts(fonts), () => native.loadFonts(fonts)); },
    addPages(options) {
      return callAsync(() => {
        validateAddPagesOptions(options);
        if (!options || !Array.isArray(options.sources)) throw argumentError('invalid_page_sources', 'Headless imports require explicit sources');
      }, () => native.addPages(options));
    },
    removePage(index) { return callAsync(() => validateRequiredPageIndex(index), () => native.removePage(index)); },
    movePage(fromIndex, toIndex) {
      return callAsync(() => { validateRequiredPageIndex(fromIndex); validateRequiredPageIndex(toIndex); }, () => native.movePage(fromIndex, toIndex));
    },
    rotatePage(index, degrees) {
      return callAsync(() => {
        validateRequiredPageIndex(index);
        if (degrees !== 90 && degrees !== 180 && degrees !== 270) throw argumentError('invalid_page_rotation', 'Use 90, 180, or 270 degrees');
      }, () => native.rotatePage(index, degrees));
    },
    finalize: () => native.finalize(),
    close: () => native.close(),
  };
  nativeDocuments.set(handle, native);
  return handle;
}

/** Loads a PDF or image into an independent native session without mounting a view. */
export function openDoc(uri: string, options?: DocumentOpenOptions): Promise<InkSignDocument> {
  return callAsync(() => {
    validateDocumentPath(uri);
    validateAddPagesOptions(options);
    if (options?.recordHistory !== undefined && typeof options.recordHistory !== 'boolean') {
      throw argumentError('invalid_document_options', 'recordHistory must be a boolean');
    }
    if (options?.androidFallbackFont !== undefined) {
      validateDocumentPath(options.androidFallbackFont.uri);
      const index = options.androidFallbackFont.collectionIndex;
      if (index !== undefined && (!Number.isInteger(index) || index < 0)) throw argumentError('invalid_fallback_font', 'A font face index must be a nonnegative integer');
    }
  }, async () => {
    const factory = NitroModules.createHybridObject<InkSignDocumentFactory>('InkSignDocumentFactory');
    return createValidatedDocument(await factory.openDoc(uri, options));
  });
}
