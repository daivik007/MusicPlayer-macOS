'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { PassThrough } = require('node:stream');
const path = require('node:path');
const { createBridge, BridgeError, MAX_LINE_CHARS } = require('./bridge.cjs');

function harness(handlers = {}, opts = {}) {
  const input = new PassThrough(); const out = []; let closed = 0;
  createBridge({ input, write: (l, cb) => { out.push(l); if (cb) cb(); }, handlers, onInputClosed: () => closed++, ...opts });
  const lines = () => out.join('').split('\n').filter(Boolean).map(l => JSON.parse(l));
  const settle = () => new Promise(r => setTimeout(r, 30));
  return { input, lines, settle, closed: () => closed, raw: () => out.join('') };
}

test('request/response matched by id, concurrent out-of-order', async () => {
  const h = harness({ a: async () => { await new Promise(r => setTimeout(r, 40)); return { n: 'a' }; }, b: async () => ({ n: 'b' }) });
  h.input.write('{"v":1,"id":"1","cmd":"a"}\n{"v":1,"id":"2","cmd":"b"}\n');
  await new Promise(r => setTimeout(r, 90));
  const l = h.lines();
  assert.deepEqual(l.map(x => x.id), ['2', '1']);
  assert.deepEqual(l.find(x => x.id === '1').result, { n: 'a' });
  assert.ok(l.every(x => x.v === 1 && x.ok === true));
});

test('chunk boundaries, CRLF, empty lines and multibyte split across chunks', async () => {
  const h = harness({ echo: async a => a });
  const msg = Buffer.from('{"id":"x","cmd":"echo","args":{"t":"héllo✓"}}\r\n\n');
  h.input.write(msg.subarray(0, 33)); h.input.write(msg.subarray(33, 36)); h.input.write(msg.subarray(36));
  await h.settle();
  assert.deepEqual(h.lines(), [{ v: 1, id: 'x', ok: true, result: { t: 'héllo✓' } }]);
});

test('malformed input yields structured errors and the bridge keeps working', async () => {
  const h = harness({ ping: async () => ({ pong: true }) });
  for (const bad of ['not json', '[1,2]', '"str"', 'null', '{"cmd":"ping"}', '{"id":"","cmd":"ping"}', '{"id":5,"cmd":"ping"}',
    '{"id":"a"}', '{"id":"a","cmd":7}', '{"id":"a","cmd":"ping","args":[]}', '{"id":"a","cmd":"ping","args":null}',
    '{"id":"a","cmd":"nope"}', '{"id":"a","cmd":"__proto__"}', '{"id":"a","cmd":"toString"}', '{"id":"a","v":2,"cmd":"ping"}', '{"id":"' + 'x'.repeat(65) + '","cmd":"ping"}'])
    h.input.write(bad + '\n');
  h.input.write('{"id":"ok","cmd":"ping"}\n');
  await h.settle();
  const l = h.lines();
  assert.equal(l.length, 17);
  assert.ok(l.slice(0, 16).every(x => x.ok === false && typeof x.error.code === 'string'));
  assert.equal(l[0].error.code, 'invalid_json');
  assert.equal(l.find(x => x.id === 'a' && x.error.code === 'unknown_command') !== undefined, true);
  assert.equal(l.find(x => x.error.code === 'unsupported_version').id, 'a');
  assert.deepEqual(l[16], { v: 1, id: 'ok', ok: true, result: { pong: true } });
});

test('oversized line is rejected once, discarded to the next newline, then recovers', async () => {
  const h = harness({ ping: async () => ({ pong: true }) });
  h.input.write('{"id":"a","cmd":"ping","args":{"p":"' + 'x'.repeat(MAX_LINE_CHARS));
  h.input.write('y'.repeat(1000));
  h.input.write('"}}\n{"id":"b","cmd":"ping"}\n');
  await h.settle();
  const l = h.lines();
  assert.equal(l.filter(x => x.error && x.error.code === 'line_too_long').length, 1);
  assert.deepEqual(l.at(-1), { v: 1, id: 'b', ok: true, result: { pong: true } });
});

test('handler errors: typed code passes through, internals are not leaked', async () => {
  const logs = []; const h = harness({ boom: async () => { throw new Error('secret path /Users/x'); }, typed: async () => { throw new BridgeError('custom', 'typed') } }, { log: m => logs.push(m) });
  h.input.write('{"id":"1","cmd":"boom"}\n{"id":"2","cmd":"typed"}\n');
  await h.settle();
  const l = h.lines();
  assert.equal(l[0].error.code, 'internal_error');
  assert.ok(!h.raw().includes('secret path'));
  assert.ok(logs.some(m => m.includes('secret path'))); // diagnostics still reach the log sink (stderr)
  assert.equal(l[1].error.code, 'custom');
});

test('handler timeout and unserializable results are reported, not hung', async () => {
  const h = harness({ hang: () => new Promise(() => {}), circ: async () => { const o = {}; o.o = o; return o; }, big: async () => ({ n: 10n }) }, { handlerTimeoutMs: 40 });
  h.input.write('{"id":"1","cmd":"hang"}\n{"id":"2","cmd":"circ"}\n{"id":"3","cmd":"big"}\n');
  await new Promise(r => setTimeout(r, 120));
  const by = Object.fromEntries(h.lines().map(x => [x.id, x]));
  assert.equal(by['1'].error.code, 'handler_timeout');
  assert.equal(by['2'].error.code, 'internal_error');
  assert.equal(by['3'].error.code, 'internal_error');
});

test('events have no id; afterResponse runs only after the response is written', async () => {
  const order = []; const input = new PassThrough();
  const b = createBridge({ input, write: (l, cb) => { order.push('write:' + (JSON.parse(l).event ?? JSON.parse(l).id)); if (cb) cb(); },
    handlers: { shutdown: async (_a, c) => { c.afterResponse(() => order.push('after')); return {}; } } });
  b.emit('runtime.ready', { x: 1 });
  input.write('{"id":"s","cmd":"shutdown"}\n');
  await new Promise(r => setTimeout(r, 30));
  assert.deepEqual(order, ['write:runtime.ready', 'write:s', 'after']);
});

test('input end flushes an unterminated final line and fires onInputClosed once', async () => {
  const h = harness({ ping: async () => ({ pong: true }) });
  h.input.write('{"id":"t","cmd":"ping"}'); h.input.end();
  await h.settle();
  assert.equal(h.lines()[0].id, 't');
  assert.equal(h.closed(), 1);
});

test('real child process: stdout carries only protocol lines, stray console.log goes to stderr, shutdown exits 0', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, 'bridge-test-host.cjs')], { stdio: ['pipe', 'pipe', 'pipe'] });
  let out = '', err = ''; child.stdout.on('data', d => out += d); child.stderr.on('data', d => err += d);
  child.stdin.write('garbage\n{"id":"1","cmd":"ping"}\n{"id":"2","cmd":"boom"}\n{"id":"3","cmd":"slow"}\n');
  while (!out.includes('"id":"3"')) await new Promise(r => setTimeout(r, 10)); // shutdown drops in-flight work by design
  child.stdin.write('{"id":"4","cmd":"shutdown"}\n');
  const code = await new Promise(r => child.on('exit', r));
  assert.equal(code, 0);
  const lines = out.split('\n').filter(Boolean).map(l => JSON.parse(l)); // would throw on any non-JSON stdout line
  assert.equal(lines[0].event, 'runtime.starting');
  assert.ok(lines.some(l => l.error && l.error.code === 'invalid_json'));
  assert.ok(lines.some(l => l.id === '1' && l.result.pong));
  assert.ok(lines.some(l => l.id === '3' && l.result.slow));
  assert.ok(lines.some(l => l.id === '4' && l.ok));
  assert.match(err, /stray console\.log/);
});

test('real child process: shutdown acknowledges while a command is pending', { timeout: 3000 }, async t => {
  const child = spawn(process.execPath, [path.join(__dirname, 'bridge-test-host.cjs')], { stdio: ['pipe', 'pipe', 'ignore'] });
  t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); });
  let stdout = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; });
  const closed = new Promise(resolve => child.once('close', resolve));
  child.stdin.write('{"id":"pending","cmd":"hang"}\n{"id":"stop","cmd":"shutdown"}\n');
  assert.equal(await closed, 0);
  const messages = stdout.trimEnd().split('\n').map(line => JSON.parse(line));
  assert.ok(messages.some(message => message.event === 'test.command-pending' && message.v === 1));
  assert.ok(messages.some(message => message.id === 'stop' && message.result.shuttingDown));
  assert.ok(!messages.some(message => message.id === 'pending'));
});

test('real child process: closing stdin (parent death) terminates the runtime', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, 'bridge-test-host.cjs')], { stdio: ['pipe', 'pipe', 'pipe'] });
  child.stdin.end();
  const code = await Promise.race([new Promise(r => child.on('exit', r)), new Promise(r => setTimeout(() => r('hung'), 3000))]);
  if (code === 'hung') child.kill('SIGKILL');
  assert.equal(code, 0);
});
