const assert = require('node:assert/strict');
const test = require('node:test');
const { createViewConnection } = require('../lib/commonjs/viewConnection.js');
const requestUserTap = connection => connection.invoke(native => native.requestUserTap());

test('attachment forwards async viewer requests in FIFO order without redispatch', async () => {
  const connection = createViewConnection();
  const calls = [];
  const firstResult = { x: 1 };
  const latestResult = { x: 2 };
  const results = [firstResult, latestResult];
  const native = { requestUserTap: () => Promise.resolve(results[calls.push('request') - 1]) };
  const first = requestUserTap(connection);
  const latest = requestUserTap(connection);
  assert.deepEqual(calls, []);
  connection.attach(native);
  connection.attach(native);
  assert.equal(await first, firstResult);
  assert.equal(await latest, latestResult);
  assert.deepEqual(calls, ['request', 'request']);
});

test('unmount rejects waiting and subsequent requests and ignores late attachment', async () => {
  const connection = createViewConnection();
  const waiting = requestUserTap(connection);
  const cancelled = assert.rejects(waiting, { message: /^operation_cancelled:/ });
  connection.unmount();
  let calls = 0;
  connection.attach({ requestUserTap: () => { calls++; return Promise.resolve(); } });
  await cancelled;
  await assert.rejects(requestUserTap(connection), { message: /^operation_cancelled:/ });
  assert.equal(calls, 0);
});

test('native mode errors settle deferred requests and later requests still work', async () => {
  const connection = createViewConnection();
  const failure = new Error('native requestUserTap failed');
  const pending = requestUserTap(connection);
  const rejected = assert.rejects(pending, error => error === failure);
  connection.attach({ requestUserTap: () => Promise.reject(failure) });
  await rejected;
  connection.attach({ requestUserTap: () => Promise.resolve({ x: 3 }) });
  assert.deepEqual(await requestUserTap(connection), { x: 3 });
});

test('Strict Mode replay preserves requests waiting for ref attachment', async () => {
  const connection = createViewConnection();
  connection.mount();
  const result = connection.invoke(async () => 'ready');
  connection.unmount();
  connection.mount();
  connection.attach({});
  assert.equal(await result, 'ready');
});
