import { argumentError } from './publicArguments';
import type { InkSignView } from './InkSignView.nitro';

/** React owns session initialization and attachment; native owns dispatched requests. */
export function createViewConnection() {
  let native: InkSignView | null = null;
  let mounted = true;
  let initialized = false;
  const pending: { dispatch: (native: InkSignView) => void; reject: (reason: unknown) => void }[] = [];

  function cancelPending(message: string) {
    const requests = pending.splice(0);
    for (const request of requests) request.reject(argumentError('operation_cancelled', message));
  }

  function getNative(): InkSignView {
    if (!mounted) throw argumentError('operation_cancelled', 'The PDF view is unmounted');
    if (!native) throw argumentError('view_not_ready', 'The native PDF view is not attached');
    return native;
  }

  function dispatch() {
    if (!native) return;
    for (const request of pending.splice(0)) request.dispatch(native);
  }

  function invoke<T>(action: (native: InkSignView) => Promise<T>, cancel = false): Promise<T> {
    if (!mounted) return Promise.reject(argumentError('operation_cancelled', 'The PDF view is unmounted'));
    if (cancel) cancelPending('An immediate close cancelled this request');
    return new Promise((resolve, reject) => {
      pending.push({ reject, dispatch(value) {
        try { action(value).then(resolve, reject); } catch (error) { reject(error); }
      } });
      dispatch();
    });
  }

  return {
    getNative,
    invoke,
    attach(value: InkSignView | null) {
      if (!mounted) return;
      native = value;
      dispatch();
    },
    mount(initialize?: () => Promise<unknown>) {
      mounted = true;
      if (initialized) return;
      initialized = true;
      if (initialize) {
        // Native reports load errors through onStateChange; cancellation is silent.
        void initialize().catch(() => {});
      }
    },
    unmount() {
      mounted = false;
      // React's Strict Mode immediately replays effects. Release the
      // attachment and pending requests only if this session stays unmounted.
      void Promise.resolve().then(() => {
        if (!mounted) {
          cancelPending('The PDF view was unmounted before native attachment');
          native = null;
        }
      });
    },
  };
}
