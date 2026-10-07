import { argumentError } from './publicArguments';
import type { InkSignView, InkSignViewMethods, PageInfo } from './InkSignView.nitro';

/** React owns attachment; native owns requests once open() is dispatched. */
export function createViewConnection() {
  let native: InkSignView | null = null;
  let mounted = true;
  let pending: {
    args: Parameters<InkSignViewMethods['open']>;
    resolve: (page: PageInfo) => void;
    reject: (reason: unknown) => void;
  } | undefined;

  function cancelPending(message: string) {
    const request = pending;
    pending = undefined;
    request?.reject(argumentError('operation_cancelled', message));
  }

  function getNative(): InkSignView {
    if (!mounted) throw argumentError('operation_cancelled', 'The PDF view is unmounted');
    if (!native) throw argumentError('view_not_ready', 'The native PDF view is not attached');
    return native;
  }

  function dispatch() {
    if (!native || !pending) return;
    const request = pending;
    pending = undefined;
    try {
      native.open(...request.args).then(request.resolve, request.reject);
    } catch (error) {
      request.reject(error);
    }
  }

  return {
    getNative,
    open(...args: Parameters<InkSignViewMethods['open']>): Promise<PageInfo> {
      if (!mounted) return Promise.reject(argumentError('operation_cancelled', 'The PDF view is unmounted'));
      cancelPending('A newer open request superseded this request');
      return new Promise((resolve, reject) => {
        pending = { args, resolve, reject };
        dispatch();
      });
    },
    attach(value: InkSignView | null) {
      if (!mounted) return;
      native = value;
      dispatch();
    },
    mount() {
      mounted = true;
    },
    unmount() {
      mounted = false;
      cancelPending('The PDF view was unmounted before native attachment');
      // React's Strict Mode immediately replays effects. Release the
      // native reference after that replay, while rejecting calls immediately.
      void Promise.resolve().then(() => {
        if (!mounted) native = null;
      });
    },
  };
}
