const assert = require('node:assert/strict');
const test = require('node:test');
const Module = require('node:module');
const React = require('react');
const { act, create } = require('react-test-renderer');
const viewConfig = require('../nitrogen/generated/shared/json/InkSignViewConfig.json');

globalThis.IS_REACT_ACT_ENVIRONMENT = true;

let attachments = 0;
const calls = [];
const native = {
  open: async path => { calls.push(path); return { pageIndex: 0 }; },
  setInkMode: async () => { calls.push('ink'); },
  setTextMode: async () => { calls.push('text'); },
  setViewMode: async () => { calls.push('view'); },
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
