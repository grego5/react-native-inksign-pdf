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
let selectedText = null;
let headlessFactory;
const platform = { OS: 'android' };
const nativeSession = {
  getPage: async () => { calls.push('session-page'); return { getInputTargets: () => [] }; },
  requestUserTap: async () => ({ pageId: 'page', pageIndex: 0, x: 10, y: 20 }),
  setViewport: async options => { calls.push(['viewport', options]); },
};
const native = {
  getPageIdsByTag: tag => { calls.push(['tag-ids', tag]); return ['report-0', 'report-1']; },
  getSelectedText: () => selectedText,
  open: async path => { calls.push(path); return { pageIndex: 0 }; },
  setMode: mode => { calls.push(mode); return nativeSession; },
  getPage: async () => { calls.push('page'); return { getInputTargets: () => [] }; },
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
let openDoc;
try {
  Module._load = function(request, parent, isMain) {
    if (request === 'react-native') {
      return { Platform: platform };
    }
    if (request === 'react-native-nitro-modules') {
      return {
        callback: value => value,
        getHostComponent: () => NativeView,
        NitroModules: { createHybridObject: name => {
          assert.equal(name, 'InkSignDocumentFactory');
          return headlessFactory;
        } },
      };
    }
    if (request === '../nitrogen/generated/shared/json/InkSignViewConfig.json') {
      return viewConfig;
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  ({ InkSignView, openDoc } = require('../lib/commonjs/index.js'));
} finally {
  Module._load = originalLoad;
}

test('iOS headless wrapper dispatches document and text operations without mounting a view', async () => {
  const previousPlatform = platform.OS;
  const mountedBefore = attachments;
  const operations = [];
  let closed = false;
  let count = 1;
  let value = '';
  const nativePage = {
    getState: () => ({ pageId: 'page-1', hasText: value !== '' }),
    resolveInputUnderline: options => { operations.push(['resolve', options.fieldName]); return 7; },
    getTextValue: id => { assert.equal(id, 7); return value; },
    setTextValue: (id, text, options) => {
      assert.equal(id, 7);
      operations.push(['write', text, options.font]);
      value = text;
    },
  };
  const nativeDocument = {
    get pageCount() { throw new Error('Use authoritative document state'); },
    getState: () => {
      if (closed) throw new Error('document_closed');
      return { documentId: 'document-1', pageCount: count, isDirty: false };
    },
    getPage: async query => { operations.push(['page', query]); return nativePage; },
    getPageIdsByTag: tag => tag === 'report' ? ['page-1'] : [],
    loadFonts: async fonts => { operations.push(['fonts', fonts[0].name]); },
    addPages: async options => {
      operations.push(['append', options.sources[0]]);
      return { addedPageCount: 1, pageCount: ++count };
    },
    finalize: async () => 'file:///output.pdf',
    close: async () => { closed = true; },
  };
  try {
    platform.OS = 'ios';
    headlessFactory = { openDoc: async (uri, options) => {
      operations.push(['open', uri, options.tag]);
      return nativeDocument;
    } };
    const document = await openDoc('file:///source.pdf', { tag: 'report' });
    assert.equal(document.pageCount, 1);
    await document.loadFonts([{ name: 'form', uri: 'file:///font.ttf' }]);
    const page = await document.getPage({ tag: 'report' });
    const id = page.resolveInputUnderline({ fieldName: 'Name' });
    page.setTextValue(id, 'Ada', { font: 'form' });
    assert.equal(page.getTextValue(id), 'Ada');
    assert.equal(page.getState().hasText, true);
    assert.equal(page.focusInputTarget, undefined);
    assert.deepEqual(document.getPageIdsByTag('report'), ['page-1']);
    await document.addPages({ sources: ['file:///attachment.pdf'] });
    assert.equal(document.pageCount, 2);
    assert.equal(await document.finalize(), 'file:///output.pdf');
    await document.close();
    assert.throws(() => document.pageCount, /document_closed/);
    assert.throws(() => document.getState(), /document_closed/);
    assert.equal(attachments, mountedBefore);
    assert.deepEqual(operations, [
      ['open', 'file:///source.pdf', 'report'], ['fonts', 'form'],
      ['page', { tag: 'report' }], ['resolve', 'Name'], ['write', 'Ada', 'form'],
      ['append', 'file:///attachment.pdf'],
    ]);
  } finally {
    platform.OS = previousPlatform;
    headlessFactory = undefined;
  }
});

test('selected text commands use native selection without preparing a page', async () => {
  const ref = React.createRef();
  const edits = [];
  let root;
  try {
    await act(async () => { root = create(React.createElement(InkSignView, { ref })); });
    const callsBefore = calls.length;
    assert.equal(ref.current.getSelectedText(), null);
    let value = 'first';
    selectedText = {
      getValue: () => value,
      setValue: text => { value = text; },
      setOptions: options => edits.push(options),
      adjustSize: delta => 16 + delta,
    };
    const text = ref.current.getSelectedText();
    assert.equal(text.getValue(), 'first');
    selectedText = null;
    assert.equal(ref.current.getSelectedText(), null);
    text.setOptions({ alignment: 'center' });
    assert.deepEqual(edits, [{ alignment: 'center' }]);
    assert.equal(text.adjustSize(1), 17);
    text.setValue('');
    assert.equal(text.getValue(), '');
    assert.equal(calls.length, callsBefore);
  } finally {
    selectedText = null;
    if (root) await act(async () => { root.unmount(); });
  }
});

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

test('mode entry is synchronous and page acquisition can use either path', async () => {
  calls.length = 0;
  const ref = React.createRef();
  function Screen() {
    React.useLayoutEffect(() => {
      assert.throws(() => ref.current.setMode('ink'), /not attached/);
    }, []);
    return React.createElement(InkSignView, { ref });
  }
  let root;
  const originalSetMode = native.setMode;
  const originalGetPage = native.getPage;
  const originalSessionGetPage = nativeSession.getPage;
  try {
    await act(async () => { root = create(React.createElement(Screen)); });
    const session = ref.current.setMode('ink');
    assert.deepEqual(calls, ['ink']);
    assert.deepEqual((await session.getPage()).getInputTargets(), []);
    assert.deepEqual((await ref.current.getPage()).getInputTargets(), []);
    await session.setViewport({ zoom: 3 });
    assert.deepEqual(calls, ['ink', 'session-page', 'page', ['viewport', { zoom: 3 }]]);
    assert.deepEqual(ref.current.getPageIdsByTag('report'), ['report-0', 'report-1']);
    assert.deepEqual(calls.at(-1), ['tag-ids', 'report']);
    let receivedQuery;
    native.getPage = async query => { receivedQuery = query; return originalGetPage(query); };
    const taggedQuery = { tag: 'report', index: 1 };
    await ref.current.getPage(taggedQuery);
    assert.deepEqual(receivedQuery, taggedQuery);
    nativeSession.getPage = async query => { receivedQuery = query; return originalSessionGetPage(query); };
    await session.getPage({ tag: 'report' });
    assert.deepEqual(receivedQuery, { tag: 'report' });
    const textOptions = { maxLines: 2 };
    let modeRequest;
    native.setMode = (mode, options) => { modeRequest = { mode, options }; return nativeSession; };
    ref.current.setMode('text', textOptions);
    assert.deepEqual(modeRequest, { mode: 'text', options: textOptions });
    const failure = new Error('operation_cancelled: Document replaced');
    native.setMode = () => { throw failure; };
    assert.throws(() => ref.current.setMode('view'), error => error === failure);
  } finally {
    native.setMode = originalSetMode;
    native.getPage = originalGetPage;
    nativeSession.getPage = originalSessionGetPage;
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
    for (const page of await Promise.all(pages)) assert.deepEqual(page.getInputTargets(), []);
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
      documentId: null, pageCount: 0, pageIndex: null, mode: 'view', isDirty: false,
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
  const originalSetMode = native.setMode;
  native.requestUserTap = () => {
    sequence.push('coords');
    return new Promise((resolve, reject) => { rejectRequest = reject; });
  };
  native.setMode = () => {
    sequence.push('view');
    rejectRequest(new Error('operation_cancelled: Coordinate request cancelled'));
    return nativeSession;
  };
  let root;
  try {
    let waiting;
    let cancelled;
    function Screen() {
      React.useEffect(() => {
        waiting = ref.current.requestUserTap();
        cancelled = assert.rejects(waiting, { message: /^operation_cancelled:/ });
        void ref.current.setMode('view');
      }, []);
      return React.createElement(InkSignView, { ref });
    }
    await act(async () => { root = create(React.createElement(Screen)); });
    await cancelled;
    assert.deepEqual(sequence, ['coords', 'view']);
  } finally {
    if (root) await act(async () => { root.unmount(); });
    delete native.requestUserTap;
    native.setMode = originalSetMode;
  }
});
