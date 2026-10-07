const assert = require('node:assert/strict');
const test = require('node:test');
const { createViewConnection } = require('../lib/commonjs/viewConnection.js');

test('open waits for attachment and dispatches only the latest request once', async () => {
  const connection = createViewConnection();
  const calls = [];
  const page = { pageIndex: 0 };
  const native = { open: async (...args) => { calls.push(args); return page; } };
  const first = connection.open('/first.pdf');
  const cancelled = assert.rejects(first, { message: /^operation_cancelled:/ });
  const viewport = { zoom: 2 };
  const latest = connection.open('/latest.pdf', viewport);
  assert.deepEqual(calls, []);
  connection.attach(native);
  connection.attach(native);
  await cancelled;
  assert.equal(await latest, page);
  assert.deepEqual(calls, [['/latest.pdf', viewport]]);
});

test('unmount rejects waiting and subsequent opens and ignores late attachment', async () => {
  const connection = createViewConnection();
  const waiting = connection.open('/pending.pdf');
  const cancelled = assert.rejects(waiting, { message: /^operation_cancelled:/ });
  connection.unmount();
  let calls = 0;
  connection.attach({ open: async () => { calls++; } });
  await cancelled;
  await assert.rejects(connection.open('/late.pdf'), { message: /^operation_cancelled:/ });
  assert.equal(calls, 0);
});

test('native open errors settle deferred requests and later opens still work', async () => {
  const connection = createViewConnection();
  const failure = new Error('native open failed');
  const pending = connection.open('/broken.pdf');
  const rejected = assert.rejects(pending, error => error === failure);
  connection.attach({ open: () => { throw failure; } });
  await rejected;
  connection.attach({ open: async () => ({ pageIndex: 1 }) });
  assert.equal((await connection.open('/valid.pdf')).pageIndex, 1);
});
