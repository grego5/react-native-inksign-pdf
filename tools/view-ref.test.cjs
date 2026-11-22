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
  selectPage: index => { calls.push(['session-select', index]); },
  getPage: async () => { calls.push('session-page'); return { getInputTargets: () => [] }; },
  requestUserTap: async () => ({ pageId: 'page', pageIndex: 0, x: 10, y: 20 }),
  setViewport: async options => { calls.push(['viewport', options]); },
};
const nativeDocument = {
  getState: () => ({ documentId: 'doc', pageCount: 1, isDirty: false }),
  getPage: async query => { calls.push(['document-page', query]); return { getInputTargets: () => [] }; },
  getPageIdsByTag: tag => { calls.push(['tag-ids', tag]); return ['report-0', 'report-1']; },
};
const native = {
  selectPage: index => { calls.push(['view-select', index]); },
  getSelectedText: () => selectedText,
  requestUserTap: async () => { calls.push('tap'); return { pageId: 'page', pageIndex: 0, x: 10, y: 20 }; },
  setMode: mode => { calls.push(mode); return nativeSession; },
};

const observedDocuments = [];
function NativeView({ hybridRef, document }) {
  observedDocuments.push(document);
  // Match Nitro: publish on creation/prop change, rather than layout reactivation.
  React.useEffect(() => {
    attachments++;
    hybridRef(native);
  }, [hybridRef]);
  return React.createElement('native-pdf');
}

const originalLoad = Module._load;
let InkSignView;
let createDocument;
let isOperationCancelled;
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
  ({ InkSignView, createDocument, isOperationCancelled } = require('../lib/commonjs/index.js'));
} finally {
  Module._load = originalLoad;
}

test('empty document attaches after a viewer mounts and populates without replacing either', async () => {
  let count = 0;
  const source = {
    getState: () => ({ documentId: count ? 'doc' : null, pageCount: count, isDirty: count > 0 }),
    addPages: async () => ({ addedPageCount: 1, pageCount: ++count }),
  };
  const options = { recordHistory: true };
  headlessFactory = { createDocument: received => {
    assert.equal(received, options);
    return source;
  } };
  const document = createDocument(options);
  assert.equal(document.pageCount, 0);
  const mountedBefore = attachments;
  const ref = React.createRef();
  let root;
  try {
    await act(async () => { root = create(React.createElement(InkSignView, { ref })); });
    assert.equal(observedDocuments.at(-1), undefined);
    const handle = ref.current;
    await act(async () => { root.update(React.createElement(InkSignView, { ref, document })); });
    assert.equal(observedDocuments.at(-1), source);
    assert.equal(ref.current, handle);
    assert.equal(attachments, mountedBefore + 1);
    await document.addPages();
    assert.equal(document.pageCount, 1);
    await act(async () => { root.update(React.createElement(InkSignView, { ref })); });
    assert.equal(observedDocuments.at(-1), undefined);
    assert.equal(document.pageCount, 1);
  } finally {
    if (root) await act(async () => { root.unmount(); });
    headlessFactory = undefined;
  }
});

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
    acceptChanges: async () => { operations.push(['accept']); },
    revertChanges: async () => { operations.push(['revert']); },
    close: async () => { closed = true; },
  };
  try {
    platform.OS = 'ios';
    headlessFactory = { createDocument: options => {
      operations.push(['create', options.sources, options.tag]);
      return nativeDocument;
    } };
    const document = createDocument({ sources: ['file:///source.pdf'], tag: 'report' });
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
    await document.acceptChanges();
    await document.revertChanges();
    await document.close();
    assert.throws(() => document.pageCount, /document_closed/);
    assert.throws(() => document.getState(), /document_closed/);
    assert.equal(attachments, mountedBefore);
    assert.deepEqual(operations, [
      ['create', ['file:///source.pdf'], 'report'], ['fonts', 'form'],
      ['page', { tag: 'report' }], ['resolve', 'Name'], ['write', 'Ada', 'form'],
      ['append', 'file:///attachment.pdf'], ['accept'], ['revert'],
    ]);
  } finally {
    platform.OS = previousPlatform;
    headlessFactory = undefined;
  }
});

test('headless imports preserve omitted and explicit selection arguments', async () => {
  const previousPlatform = platform.OS;
  const calls = [];
  const nativeDocument = {
    getState: () => ({ documentId: 'picked-document', pageCount: 2, isDirty: false }),
    addPages: async options => {
      calls.push(['append', options]);
      return { addedPageCount: options?.sources?.length ?? 1, pageCount: 3 };
    },
    close: async () => {},
  };
  try {
    platform.OS = 'ios';
    headlessFactory = { createDocument: options => {
      calls.push(['create', options]);
      return nativeDocument;
    } };

    const picked = createDocument();
    assert.equal((await picked.addPages()).addedPageCount, 1);
    const explicit = createDocument({ type: 'image', sources: ['file:///image.jpg'] });
    assert.equal((await explicit.addPages({ type: 'pdf', sources: ['file:///source.pdf'] })).addedPageCount, 1);

    assert.deepEqual(calls, [
      ['create', undefined],
      ['append', undefined],
      ['create', { type: 'image', sources: ['file:///image.jpg'] }],
      ['append', { type: 'pdf', sources: ['file:///source.pdf'] }],
    ]);
  } finally {
    platform.OS = previousPlatform;
    headlessFactory = undefined;
  }
});

test('Android fallback font validates only on Android with a font error', () => {
  const previousPlatform = platform.OS;
  const options = { androidFallbackFont: { uri: '' } };
  try {
    headlessFactory = { createDocument: () => ({
      getState: () => ({ documentId: 'font-document', pageCount: 0, isDirty: false }),
    }) };
    platform.OS = 'ios';
    createDocument(options);
    platform.OS = 'android';
    assert.throws(() => createDocument(options), /^Error: invalid_fallback_font:/);
  } finally {
    platform.OS = previousPlatform;
    headlessFactory = undefined;
  }
});

test('native lifecycle cancellation remains recognizable through imports', async () => {
  const previousPlatform = platform.OS;
  try {
    platform.OS = 'ios';
    headlessFactory = { createDocument: () => ({
      addPages: async () => { throw new Error('operation_cancelled: host destroyed'); },
    }) };
    await assert.rejects(createDocument().addPages(), error => isOperationCancelled(error));
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
    await act(async () => { root = create(React.createElement(InkSignView, { ref, document: nativeDocument })); });
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
  const propsFor = version => ({
    document: nativeDocument,
    ...Object.fromEntries(names.map(name =>
      [name, value => received.push([version, name, value])])),
  });
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
    await act(async () => { root.update(React.createElement(InkSignView, { document: nativeDocument })); });
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

test('normal ref keeps its handle through Suspense hide/reveal', async () => {
  calls.length = 0;
  attachments = 0;
  const ref = React.createRef();
  const blocker = new Promise(() => {});
  let root;

  function Gate({ blocked }) {
    if (blocked) throw blocker;
    return null;
  }
  function Screen({ blocked }) {
    return React.createElement(React.Suspense, { fallback: 'loading' },
      React.createElement(InkSignView, { ref, document: nativeDocument }), React.createElement(Gate, { blocked }));
  }

  try {
    await act(async () => { root = create(React.createElement(Screen, { blocked: false })); });
    const firstSession = ref.current.setMode('ink');
    assert.deepEqual((await firstSession.getPage()).getInputTargets(), []);
    assert.deepEqual([...calls], ['ink', 'session-page']);
    const handle = ref.current;

    await act(async () => { root.update(React.createElement(Screen, { blocked: true })); });
    assert.equal(root.toJSON(), 'loading');
    assert.equal(ref.current, null);
    // Reveal in a later task, after the original cleanup microtask would run.
    await new Promise(resolve => setImmediate(resolve));
    await act(async () => { root.update(React.createElement(Screen, { blocked: false })); });
    assert.equal(ref.current, handle);
    assert.equal(attachments, 1);

    const reopened = handle.setMode('ink').getPage();
    assert.deepEqual([...calls], ['ink', 'session-page', 'ink', 'session-page']);
    assert.deepEqual((await reopened).getInputTargets(), []);
    await act(async () => { root.unmount(); });
    assert.equal(ref.current, null);
  } finally {
    if (root) await act(async () => { root.unmount(); });
  }
});

test('Strict Mode effect replay leaves the normal ref attached', async () => {
  const ref = React.createRef();
  const requests = [];
  function Screen() {
    React.useLayoutEffect(() => {
      const request = ref.current.requestUserTap();
      request.catch(() => {});
      requests.push(request);
    }, []);
    return React.createElement(InkSignView, { ref, document: nativeDocument });
  }
  let root;
  try {
    await act(async () => {
      root = create(React.createElement(React.StrictMode, null, React.createElement(Screen)));
    });
    assert.ok(ref.current);
    assert.deepEqual(await requests.at(-1), { pageId: 'page', pageIndex: 0, x: 10, y: 20 });
  } finally {
    if (root) await act(async () => { root.unmount(); });
  }
});

test('mode-session and document handles acquire pages independently', async () => {
  calls.length = 0;
  const ref = React.createRef();
  function Screen() {
    React.useLayoutEffect(() => {
      assert.throws(() => ref.current.setMode('ink'), /not attached/);
    }, []);
    return React.createElement(InkSignView, { ref, document: nativeDocument });
  }
  let root;
  const originalSetMode = native.setMode;
  const originalSessionGetPage = nativeSession.getPage;
  try {
    await act(async () => { root = create(React.createElement(Screen)); });
    const session = ref.current.setMode('ink');
    assert.deepEqual(calls, ['ink']);
    assert.deepEqual((await session.getPage()).getInputTargets(), []);
    assert.deepEqual((await nativeDocument.getPage()).getInputTargets(), []);
    await session.setViewport({ zoom: 3 });
    assert.deepEqual(calls, ['ink', 'session-page', ['document-page', undefined], ['viewport', { zoom: 3 }]]);
    ref.current.selectPage(2);
    session.selectPage(0);
    assert.deepEqual(calls.slice(-2), [['view-select', 2], ['session-select', 0]]);
    assert.deepEqual(nativeDocument.getPageIdsByTag('report'), ['report-0', 'report-1']);
    assert.deepEqual(calls.at(-1), ['tag-ids', 'report']);
    let receivedQuery;
    const originalDocumentGetPage = nativeDocument.getPage;
    nativeDocument.getPage = async query => { receivedQuery = query; return originalDocumentGetPage(query); };
    const taggedQuery = { tag: 'report', index: 1 };
    await nativeDocument.getPage(taggedQuery);
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
    nativeSession.getPage = originalSessionGetPage;
    if (root) await act(async () => { root.unmount(); });
  }
});

test('required document prop passes native ownership through updates and unmount without closing', async () => {
  let closes = 0;
  const source = { getState: () => ({ documentId: 'doc', pageCount: 1, isDirty: false }), close: async () => { closes++; } };
  headlessFactory = { createDocument: () => source };
  const document = createDocument({ sources: ['/document.pdf'] });
  let root;
  try {
    await act(async () => { root = create(React.createElement(InkSignView, { document })); });
    assert.equal(observedDocuments.at(-1), source);
    await act(async () => { root.update(React.createElement(InkSignView, { document, outlineColor: '#123456' })); });
    assert.equal(observedDocuments.at(-1), source);
    assert.equal(document.getState().documentId, 'doc');
    await act(async () => { root.update(React.createElement(InkSignView, { document })); });
    assert.equal(observedDocuments.at(-1), source);
    await act(async () => { root.unmount(); });
    root = undefined;
    assert.equal(closes, 0);
    await document.close();
    assert.equal(closes, 1);
  } finally { if (root) await act(async () => { root.unmount(); }); }
});

test('DocumentOptions prop reaches the native view as options for view-owned documents', async () => {
  const options = { sources: ['/document.pdf'], recordHistory: false };
  let root;
  try {
    await act(async () => { root = create(React.createElement(InkSignView, { document: options })); });
    assert.equal(observedDocuments.at(-1), options);
  } finally { if (root) await act(async () => { root.unmount(); }); }
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
      return React.createElement(InkSignView, { ref, document: nativeDocument });
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
