import React, { useCallback, useMemo } from 'react';
import { callback, getHostComponent } from 'react-native-nitro-modules';
import InkSignViewConfig from '../nitrogen/generated/shared/json/InkSignViewConfig.json';

import type {
  PageInfo,
  PageType,
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

export type InkSignViewHandle = InkSignViewNativeHandle;

const NativeInkSignView = getHostComponent<InkSignViewProps, InkSignViewMethods>(
  'InkSignView',
  () => InkSignViewConfig,
);

type NativeInkSignViewProps = React.ComponentProps<typeof NativeInkSignView>;
type InkSignViewComponentProps = Omit<NativeInkSignViewProps, 'hybridRef' | 'onStateChange' | 'onPageChange'> & {
  onStateChange?: InkSignViewProps['onStateChange'];
  onPageChange?: InkSignViewProps['onPageChange'];
};

export const InkSignView = React.forwardRef<InkSignViewNativeHandle, InkSignViewComponentProps>(
  (props, ref) => {
    const { onStateChange, onPageChange, ...nativeProps } = props;
    const wrappedHybridRef = useMemo(
      () =>
        callback((value: InkSignViewNativeHandle | null) => {
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

    return React.createElement(NativeInkSignView, {
      ...nativeProps,
      hybridRef: wrappedHybridRef,
      onStateChange: wrappedStateChange,
      onPageChange: wrappedPageChange,
    });
  },
);
