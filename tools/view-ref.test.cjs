const assert = require('node:assert/strict');
const test = require('node:test');
const Module = require('node:module');
const React = require('react');
const { act } = React;
const { create } = require('react-test-renderer');
const viewConfig = require('../nitrogen/generated/shared/json/InkSignViewConfig.json');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

let attachments = 0;
const calls = [];
const native = {
  open: async path => { calls.push(path); return { pageIndex: 0 }; },
  setInkMode: async () => { calls.push('ink'); },
  setTextMode: async () => { calls.push('text'); },
  setViewMode: async () => { calls.push('view'); },
  getPage: async () => { calls.push('page'); return { getTextEntries: () => [] }; },
};

function NativeView({ hybridRef }) {
  // Match Nitro: publish on creation/prop change, rather than layout reactivation.
  React.useEffect(() => {
    attachments++;
    hybridRef(native);
  }, [hybridRef]);
  return React.createElement('native-pdf');
}

const originalLoad = Module._load;
let InkSignView;
try {
  Module._load = function(request, parent, isMain) {
    if (request === 'react-native-nitro-modules') {
      return { callback: value => value, getHostComponent: () => NativeView };
    }
    if (request === '../nitrogen/generated/shared/json/InkSignViewConfig.json') {
      return viewConfig;
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  ({ InkSignView } = require('../lib/commonjs/index.js'));
} finally {
  Module._load = originalLoad;
}

test('native event subscriptions stay stable while forwarding to the latest committed callbacks', async () => {
  const names = ['onStateChange', 'onPageChange', 'onTextSelectionChange', 'onZoomChange'];
  const received = [];
  const propsFor = version => Object.fromEntries(names.map(name =>
    [name, value => received.push([version, name, value])]));
  let root;
  try {
    await act(async () => { root = create(React.createElement(InkSignView, propsFor('first'))); });
    const original = root.root.findByType(NativeView).props;
    await act(async () => { root.update(React.createElement(InkSignView, propsFor('latest'))); });
    const updated = root.root.findByType(NativeView).props;
    for (const name of names) {
      assert.equal(updated[name], original[name]);
      updated[name](name);
    }
    assert.deepEqual(received, names.map(name => ['latest', name, name]));
    await act(async () => { root.update(React.createElement(InkSignView)); });
    for (const name of names) {
      assert.equal(root.root.findByType(NativeView).props[name], undefined);
      original[name]('late');
    }
    assert.equal(received.length, names.length);
    await act(async () => { root.update(React.createElement(InkSignView, propsFor('resubscribed'))); });
    for (const name of names) {
      const subscribed = root.root.findByType(NativeView).props[name];
      assert.equal(subscribed, original[name]);
      subscribed(name);
    }
    assert.deepEqual(received.slice(names.length), names.map(name => ['resubscribed', name, name]));
  } finally {
    if (root) await act(async () => { root.unmount(); });
  }
});

test('normal ref opens before attachment and keeps its handle through Suspense hide/reveal', async () => {
  calls.length = 0;
  attachments = 0;
  const ref = React.createRef();
  const blocker = new Promise(() => {});
  let initialOpen;
  let root;

  function Gate({ blocked }) {
    if (blocked) throw blocker;
    return null;
  }
  function Screen({ blocked }) {
    React.useLayoutEffect(() => {
      initialOpen = ref.current.open('/initial.pdf');
    }, []);
    return React.createElement(React.Suspense, { fallback: 'loading' },
      React.createElement(InkSignView, { ref }), React.createElement(Gate, { blocked }));
  }

  try {
    await act(async () => { root = create(React.createElement(Screen, { blocked: false })); });
    assert.equal((await initialOpen).pageIndex, 0);
    assert.deepEqual([...calls], ['/initial.pdf']);
    const handle = ref.current;

    await act(async () => { root.update(React.createElement(Screen, { blocked: true })); });
    assert.equal(root.toJSON(), 'loading');
    assert.equal(ref.current, null);
    // Reveal in a later task, after the original cleanup microtask would run.
    await new Promise(resolve => setImmediate(resolve));
    await act(async () => { root.update(React.createElement(Screen, { blocked: false })); });
    assert.equal(ref.current, handle);
    assert.equal(attachments, 1);

    const reopened = handle.open('/revealed.pdf');
    reopened.catch(() => {});
    assert.deepEqual([...calls], ['/initial.pdf', '/revealed.pdf']);
    assert.equal((await reopened).pageIndex, 0);
    await act(async () => { root.unmount(); });
    await assert.rejects(handle.open('/unmounted.pdf'), { message: /^operation_cancelled:/ });
  } finally {
    if (root) await act(async () => { root.unmount(); });
  }
});

test('Strict Mode effect replay leaves the normal ref attached', async () => {
  const ref = React.createRef();
  const opens = [];
  function Screen() {
    React.useLayoutEffect(() => {
      const request = ref.current.open('/strict.pdf');
      request.catch(() => {});
      opens.push(request);
    }, []);
    return React.createElement(InkSignView, { ref });
  }
  let root;
  try {
    await act(async () => {
      root = create(React.createElement(React.StrictMode, null, React.createElement(Screen)));
    });
    assert.ok(ref.current);
    assert.equal((await opens.at(-1)).pageIndex, 0);
  } finally {
    if (root) await act(async () => { root.unmount(); });
  }
});

test('mode promises are buffered before attachment and forward native rejection', async () => {
  calls.length = 0;
  const ref = React.createRef();
  const requests = [];
  function Screen() {
    React.useLayoutEffect(() => {
      requests.push(ref.current.open('/modes.pdf'));
      requests.push(ref.current.setInkMode());
      requests.push(ref.current.setTextMode());
      requests.push(ref.current.setViewMode());
    }, []);
    return React.createElement(InkSignView, { ref });
  }
  let root;
  const originalViewMode = native.setViewMode;
  try {
    await act(async () => { root = create(React.createElement(Screen)); });
    await Promise.all(requests);
    assert.deepEqual(calls, ['/modes.pdf', 'ink', 'text', 'view']);
    const failure = new Error('operation_cancelled: Document replaced');
    native.setViewMode = async () => { throw failure; };
    await assert.rejects(ref.current.setViewMode(), error => error === failure);
  } finally {
    native.setViewMode = originalViewMode;
    if (root) await act(async () => { root.unmount(); });
  }
});

test('initialDocument opens before ref commands, ignores prop changes, and reloads on a new key', async () => {
  calls.length = 0;
  const ref = React.createRef();
  const pages = [];
  function Screen({ session, path }) {
    React.useLayoutEffect(() => {
      pages.push(ref.current.getPage());
    }, [session]);
    return React.createElement(InkSignView, { key: session, ref, initialDocument: path });
  }
  const render = (session, path) => React.createElement(React.StrictMode, null,
    React.createElement(Screen, { session, path }));
  let root;
  try {
    await act(async () => { root = create(render('first', '/session.pdf')); });
    for (const page of await Promise.all(pages)) assert.deepEqual(page.getTextEntries(), []);
    assert.equal(calls[0], '/session.pdf');
    assert.equal(calls.filter(value => value === '/session.pdf').length, 1);
    const firstHandle = ref.current;

    await act(async () => { root.update(render('first', '/ignored.pdf')); });
    assert.equal(ref.current, firstHandle);
    assert.ok(!calls.includes('/ignored.pdf'));

    await act(async () => { root.update(render('second', '/session.pdf')); });
    await Promise.all(pages);
    assert.notEqual(ref.current, firstHandle);
    assert.equal(calls.filter(value => value === '/session.pdf').length, 2);
    assert.ok(calls.lastIndexOf('/session.pdf') < calls.lastIndexOf('page'));
    await assert.rejects(firstHandle.getPage(), { message: /^operation_cancelled:/ });
  } finally {
    if (root) await act(async () => { root.unmount(); });
  }
});

test('initial load errors use the current callback and ignore retired sessions', async () => {
  const originalOpen = native.open;
  const pending = new Map();
  native.open = path => new Promise((resolve, reject) => pending.set(path, { resolve, reject }));
  const retiredErrors = [];
  const firstErrors = [];
  const latestErrors = [];
  let root;
  try {
    await act(async () => {
      root = create(React.createElement(InkSignView, {
        key: 'old', initialDocument: '/old.pdf', onStateChange: state => retiredErrors.push(state),
      }));
    });
    await act(async () => {
      root.update(React.createElement(InkSignView, {
        key: 'new', initialDocument: '/new.pdf', onStateChange: state => firstErrors.push(state),
      }));
    });
    await act(async () => {
      root.update(React.createElement(InkSignView, {
        key: 'new', initialDocument: '/new.pdf', onStateChange: state => latestErrors.push(state),
      }));
    });
    const failure = new Error('pdf_load_failed: unreadable PDF');
    const snapshot = {
      documentId: null, mode: 'view', canUndo: false, canRedo: false, isDirty: false,
      error: failure.message,
    };
    await act(async () => {
      pending.get('/old.pdf').reject(new Error('operation_cancelled: Retired session'));
      // Native publishes the load failure before rejecting the initial open.
      root.root.findByType(NativeView).props.onStateChange(snapshot);
      pending.get('/new.pdf').reject(failure);
    });
    assert.deepEqual(retiredErrors, []);
    assert.deepEqual(firstErrors, []);
    assert.deepEqual(latestErrors, [snapshot]);
  } finally {
    native.open = originalOpen;
    if (root) await act(async () => { root.unmount(); });
  }
});

test('cancelled initial loading does not synthesize a viewer error', async () => {
  const originalOpen = native.open;
  const originalClose = native.close;
  let rejectOpen;
  native.open = () => new Promise((resolve, reject) => { rejectOpen = reject; });
  native.close = async cancelPending => {
    assert.equal(cancelPending, true);
    rejectOpen(new Error('operation_cancelled: Immediate close'));
  };
  const ref = React.createRef();
  const states = [];
  let root;
  try {
    await act(async () => {
      root = create(React.createElement(InkSignView, {
        ref, initialDocument: '/cancelled.pdf', onStateChange: state => states.push(state),
      }));
    });
    await act(async () => {
      await ref.current.close(true);
    });
    assert.deepEqual(states, []);
  } finally {
    native.open = originalOpen;
    native.close = originalClose;
    if (root) await act(async () => { root.unmount(); });
  }
});

test('view mode dispatches while the coordinate request is still waiting', async () => {
  const ref = React.createRef();
  let rejectRequest;
  const sequence = [];
  const originalSetViewMode = native.setViewMode;
  native.getPageCoords = () => {
    sequence.push('coords');
    return new Promise((resolve, reject) => { rejectRequest = reject; });
  };
  native.setViewMode = async () => {
    sequence.push('view');
    rejectRequest(new Error('operation_cancelled: Coordinate request cancelled'));
  };
  let root;
  try {
    let waiting;
    let cancelled;
    function Screen() {
      React.useLayoutEffect(() => {
        waiting = ref.current.getPageCoords();
        cancelled = assert.rejects(waiting, { message: /^operation_cancelled:/ });
        void ref.current.setViewMode();
      }, []);
      return React.createElement(InkSignView, { ref });
    }
    await act(async () => { root = create(React.createElement(Screen)); });
    await cancelled;
    assert.deepEqual(sequence, ['coords', 'view']);
  } finally {
    if (root) await act(async () => { root.unmount(); });
    delete native.getPageCoords;
    native.setViewMode = originalSetViewMode;
  }
});
