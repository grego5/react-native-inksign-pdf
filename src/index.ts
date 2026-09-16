import React, { useCallback, useMemo } from 'react';
import { callback, getHostComponent } from 'react-native-nitro-modules';
import PdfViewConfig from '../nitrogen/generated/shared/json/PdfViewConfig.json';

import type {
  PageInfo,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  PdfViewProps,
  StateChangeEvent,
  InteractionMode,
  PdfView as PdfViewNativeHandle,
  PdfViewMethods,
} from './PdfView.nitro';

export type {
  PageInfo,
  StrokeColor,
  TextColor,
  DoubleTapOptions,
  Viewport,
  ViewportOptions,
  PdfViewProps,
  StateChangeEvent,
  InteractionMode,
  PdfViewMethods,
};

export type PdfViewHandle = PdfViewNativeHandle;

const NativePdfView = getHostComponent<PdfViewProps, PdfViewMethods>(
  'PdfView',
  () => PdfViewConfig,
);

type NativePdfViewProps = React.ComponentProps<typeof NativePdfView>;
type PdfViewComponentProps = Omit<NativePdfViewProps, 'hybridRef' | 'onStateChange' | 'onPageChange'> & {
  onStateChange?: PdfViewProps['onStateChange'];
  onPageChange?: PdfViewProps['onPageChange'];
};

export const PdfView = React.forwardRef<PdfViewNativeHandle, PdfViewComponentProps>(
  (props, ref) => {
    const { onStateChange, onPageChange, ...nativeProps } = props;
    const wrappedHybridRef = useMemo(
      () =>
        callback((value: PdfViewNativeHandle | null) => {
          if (typeof ref === 'function') {
            ref(value);
          } else if (ref !== null) {
            ref.current = value;
          }
        }),
      [ref],
    );
    const wrappedStateChange = useMemo(() => callback(onStateChange), [onStateChange]);
    const wrappedPageChange = useMemo(() => callback(onPageChange), [onPageChange]);

    return React.createElement(NativePdfView, {
      ...nativeProps,
      hybridRef: wrappedHybridRef,
      onStateChange: wrappedStateChange,
      onPageChange: wrappedPageChange,
    });
  },
);
