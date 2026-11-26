'use strict';
// M4B: newline-delimited JSON (NDJSON) bridge over stdio. Pure Node, no Electron imports, so it is unit-testable.
//
// Wire format, one JSON object per line, UTF-8, "\n" terminated:
//   request  (parent -> runtime): {"v":1,"id":"<1-64 chars>","cmd":"ping","args":{}}
//   response (runtime -> parent): {"v":1,"id":"<same id>","ok":true,"result":{...}}
//                                 {"v":1,"id":"<same id>|null","ok":false,"error":{"code":"...","message":"..."}}
//   event    (runtime -> parent): {"v":1,"event":"runtime.ready","data":{...}}   (no id)
// Only protocol lines go to the `write` sink (stdout). Diagnostics must go to stderr via `log`.
const { StringDecoder } = require('node:string_decoder');

const PROTOCOL_VERSION = 1;
const MAX_LINE_CHARS = 64 * 1024;
const MAX_ID_CHARS = 64;
const HANDLER_TIMEOUT_MS = 15000;

class BridgeError extends Error {
  constructor(code, message) { super(message); this.name = 'BridgeError'; this.code = code; }
}

function stringify(obj) {
  try { return JSON.stringify(obj); } catch { return null; }
}

function createBridge({ input, write, handlers, log = () => {}, onInputClosed = () => {}, handlerTimeoutMs = HANDLER_TIMEOUT_MS }) {
  const decoder = new StringDecoder('utf8');
  let buffer = '';
  let discarding = false;
  let inputClosed = false;

  function writeLine(obj, cb) {
    const line = stringify(obj);
    if (line === null) { log('bridge: dropped unserializable message'); if (cb) cb(); return false; }
    try { write(line + '\n', cb); } catch (e) { log('bridge: write failed: ' + (e && e.message)); if (cb) cb(); return false; }
    return true;
  }
  function respondError(id, code, message, after) {
    writeLine({ v: PROTOCOL_VERSION, id, ok: false, error: { code, message } }, after);
  }
  function respondOk(id, result, after) {
    const msg = { v: PROTOCOL_VERSION, id, ok: true, result: result === undefined ? null : result };
    if (stringify(msg) === null) return respondError(id, 'internal_error', 'Result was not serializable', after);
    writeLine(msg, after);
  }
  function emit(event, data = {}, cb) {
    return writeLine({ v: PROTOCOL_VERSION, event, data }, cb);
  }

  async function dispatch(msg) {
    const id = typeof msg.id === 'string' && msg.id.length > 0 && msg.id.length <= MAX_ID_CHARS ? msg.id : null;
    if (id === null) return respondError(null, 'invalid_request', 'Missing or invalid id (non-empty string, max 64 chars)');
    if (msg.v !== undefined && msg.v !== PROTOCOL_VERSION) return respondError(id, 'unsupported_version', 'Only protocol version ' + PROTOCOL_VERSION + ' is supported');
    if (typeof msg.cmd !== 'string' || msg.cmd.length === 0 || msg.cmd.length > 64) return respondError(id, 'invalid_request', 'Missing or invalid cmd');
    if (msg.args !== undefined && (msg.args === null || typeof msg.args !== 'object' || Array.isArray(msg.args))) return respondError(id, 'invalid_request', 'args must be an object');
    if (!Object.prototype.hasOwnProperty.call(handlers, msg.cmd)) return respondError(id, 'unknown_command', 'Unknown command');

    const after = [];
    const ctx = { afterResponse: fn => after.push(fn) };
    const runAfter = () => { for (const fn of after) { try { fn(); } catch (e) { log('bridge: afterResponse failed: ' + (e && e.message)); } } };
    let timer;
    try {
      const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new BridgeError('handler_timeout', 'Command timed out in runtime')), handlerTimeoutMs); });
      const result = await Promise.race([Promise.resolve().then(() => handlers[msg.cmd](msg.args ?? {}, ctx)), timeout]);
      respondOk(id, result, runAfter);
    } catch (e) {
      if (e instanceof BridgeError) respondError(id, e.code, e.message, runAfter);
      else { log('bridge: handler "' + msg.cmd + '" failed: ' + (e && e.message)); respondError(id, 'internal_error', 'Command failed', runAfter); }
    } finally { clearTimeout(timer); }
  }

  function handleLine(raw) {
    const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
    if (line.trim() === '') return;
    if (line.length > MAX_LINE_CHARS) return respondError(null, 'line_too_long', 'Line exceeds ' + MAX_LINE_CHARS + ' characters');
    let msg;
    try { msg = JSON.parse(line); } catch { return respondError(null, 'invalid_json', 'Line is not valid JSON'); }
    if (msg === null || typeof msg !== 'object' || Array.isArray(msg)) return respondError(null, 'invalid_request', 'Message must be a JSON object');
    dispatch(msg).catch(e => log('bridge: dispatch failed: ' + (e && e.message)));
  }

  function ingest(text) {
    buffer += text;
    let idx = buffer.indexOf('\n');
    while (idx !== -1) {
      const line = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 1);
      if (discarding) discarding = false; else handleLine(line);
      idx = buffer.indexOf('\n');
    }
    if (discarding) buffer = '';
    else if (buffer.length > MAX_LINE_CHARS) { respondError(null, 'line_too_long', 'Line exceeds ' + MAX_LINE_CHARS + ' characters'); buffer = ''; discarding = true; }
  }

  function closeInput() {
    if (inputClosed) return;
    inputClosed = true;
    const tail = buffer + decoder.end();
    buffer = '';
    if (tail.trim() !== '' && !discarding) handleLine(tail);
    onInputClosed();
  }

  input.on('data', chunk => ingest(typeof chunk === 'string' ? chunk : decoder.write(chunk)));
  input.on('end', closeInput);
  input.on('close', closeInput);
  input.on('error', e => { log('bridge: stdin error: ' + (e && e.message)); closeInput(); });

  return { emit };
}

module.exports = { createBridge, BridgeError, PROTOCOL_VERSION, MAX_LINE_CHARS, MAX_ID_CHARS };
