const assert = require('node:assert/strict');
const test = require('node:test');
const { createViewConnection } = require('../lib/commonjs/viewConnection.js');
const open = (connection, ...args) => connection.invoke(native => native.open(...args));

test('attachment forwards all document requests in FIFO order without redispatch', async () => {
  const connection = createViewConnection();
  const calls = [];
  const page = { pageIndex: 0 };
  const native = { open: async (...args) => { calls.push(args); return page; } };
  const first = open(connection, '/first.pdf');
  const viewport = { zoom: 2 };
  const latest = open(connection, '/latest.pdf', viewport);
  assert.deepEqual(calls, []);
  connection.attach(native);
  connection.attach(native);
  assert.equal(await first, page);
  assert.equal(await latest, page);
  assert.deepEqual(calls, [['/first.pdf'], ['/latest.pdf', viewport]]);
});

test('immediate close cancels undelivered commands and remains first for attachment', async () => {
  const connection = createViewConnection();
  const first = open(connection, '/first.pdf');
  const rejected = assert.rejects(first, { message: /^operation_cancelled:/ });
  const calls = [];
  const closing = connection.invoke(native => native.close(true), true);
  const next = open(connection, '/next.pdf');
  connection.attach({
    close: async immediate => { calls.push(['close', immediate]); },
    open: async path => { calls.push(['open', path]); return { pageIndex: 0 }; },
  });
  await rejected;
  await closing;
  await next;
  assert.deepEqual(calls, [['close', true], ['open', '/next.pdf']]);
});

test('unmount rejects waiting and subsequent opens and ignores late attachment', async () => {
  const connection = createViewConnection();
  const waiting = open(connection, '/pending.pdf');
  const cancelled = assert.rejects(waiting, { message: /^operation_cancelled:/ });
  connection.unmount();
  let calls = 0;
  connection.attach({ open: async () => { calls++; } });
  await cancelled;
  await assert.rejects(open(connection, '/late.pdf'), { message: /^operation_cancelled:/ });
  assert.equal(calls, 0);
});

test('native open errors settle deferred requests and later opens still work', async () => {
  const connection = createViewConnection();
  const failure = new Error('native open failed');
  const pending = open(connection, '/broken.pdf');
  const rejected = assert.rejects(pending, error => error === failure);
  connection.attach({ open: () => { throw failure; } });
  await rejected;
  connection.attach({ open: async () => ({ pageIndex: 1 }) });
  assert.equal((await open(connection, '/valid.pdf')).pageIndex, 1);
});

test('Strict Mode replay preserves initialization waiting for attachment', async () => {
  const connection = createViewConnection();
  const calls = [];
  let initialOpen;
  const initialize = () => (initialOpen = open(connection, '/initial.pdf'));
  connection.mount(initialize);
  connection.unmount();
  connection.mount(initialize);
  await Promise.resolve();
  connection.attach({ open: async path => { calls.push(path); return { pageIndex: 0 }; } });
  assert.equal((await initialOpen).pageIndex, 0);
  assert.deepEqual(calls, ['/initial.pdf']);
});
