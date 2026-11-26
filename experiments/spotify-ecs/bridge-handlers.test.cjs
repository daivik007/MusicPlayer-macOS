'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createHandlers } = require('./bridge-handlers.cjs');
const { trusted } = require('./permission-policy.cjs');

function make({ url = 'https://open.spotify.com/', cookies = [], probe, audible = false, noWindow = false } = {}) {
  const quits = [];
  const wc = { getURL: () => url, isLoading: () => false, isCurrentlyAudible: () => audible, isAudioMuted: () => false,
    executeJavaScript: async () => probe, session: { cookies: { get: async () => cookies } } };
  const h = createHandlers({ pid: 42, startedAtMs: 1000, now: () => 5000, versions: { electron: 'e', chrome: 'c', node: 'n', app: 'a' },
    config: { sessionMode: 'persistent', uaMode: 'clean-chromium' }, getWebContents: () => (noWindow ? null : wc), isReady: () => true, trusted, requestQuit: r => quits.push(r) });
  return { h, quits };
}
const ctx = () => { const after = []; return { c: { afterResponse: f => after.push(f) }, after }; };

test('ping and runtime.status', async () => {
  const { h } = make();
  assert.deepEqual(await h.ping({}, ctx().c), { pong: true, time: 5000 });
  const s = await h['runtime.status']({}, ctx().c);
  assert.equal(s.uptimeMs, 4000); assert.equal(s.uaMode, 'clean-chromium'); assert.equal(s.page.trusted, true); assert.equal(s.page.loginPage, false);
});

test('auth.status: signed-in/out by sp_dc presence, expiry, wrong domain; value is never returned', async () => {
  const good = { name: 'sp_dc', domain: '.spotify.com', value: 'SECRET', expirationDate: 9999999 };
  let r = await make({ cookies: [good] }).h['auth.status']();
  assert.equal(r.state, 'signed-in'); assert.ok(!JSON.stringify(r).includes('SECRET'));
  assert.equal((await make({ cookies: [] }).h['auth.status']()).state, 'signed-out');
  assert.equal((await make({ cookies: [{ ...good, expirationDate: 1 }] }).h['auth.status']()).state, 'signed-out');
  assert.equal((await make({ cookies: [{ ...good, domain: '.evil.com' }] }).h['auth.status']()).state, 'signed-out');
  assert.equal((await make({ cookies: [{ ...good, domain: '.notspotify.com' }] }).h['auth.status']()).state, 'signed-out');
  assert.equal((await make({ noWindow: true }).h['auth.status']()).state, 'unknown');
  assert.equal((await make({ url: 'https://accounts.spotify.com/login', cookies: [] }).h['auth.status']()).loginPage, true);
});

test('playback.state: playing, paused, idle, untrusted page, hostile page data is sanitized', async () => {
  let r = await make({ audible: true, probe: { mediaSession: { playbackState: 'playing', title: 'T', artist: 'A', album: 'B' }, element: { paused: false, ended: false, currentTime: 12.5, duration: 200, readyState: 4, muted: false }, elementCount: 1 } }).h['playback.state']();
  assert.equal(r.status, 'playing'); assert.equal(r.element.currentTimeSec, 12.5); assert.equal(r.mediaSession.title, 'T');
  r = await make({ probe: { mediaSession: { playbackState: 'paused', title: 'T' }, element: { paused: true, ended: false, currentTime: 30, duration: 200 }, elementCount: 1 } }).h['playback.state']();
  assert.equal(r.status, 'paused');
  r = await make({ probe: { mediaSession: null, element: null, elementCount: 0 } }).h['playback.state']();
  assert.equal(r.status, 'idle');
  assert.deepEqual(await make({ url: 'https://example.com/', probe: {} }).h['playback.state'](), { available: false, reason: 'page_not_spotify_player' });
  assert.equal((await make({ noWindow: true }).h['playback.state']()).reason, 'not_ready');
  r = await make({ probe: { mediaSession: { playbackState: '<script>', title: 'x'.repeat(5000), artist: 7 }, element: { paused: 'yes', currentTime: 'NaN', duration: Infinity }, elementCount: 'many' } }).h['playback.state']();
  assert.equal(r.mediaSession.playbackState, 'none'); assert.equal(r.mediaSession.title.length, 200); assert.equal(r.mediaSession.artist, null);
  assert.equal(r.element.currentTimeSec, null); assert.equal(r.element.durationSec, null); assert.equal(r.elementCount, null);
});

test('shutdown quits only after the response (afterResponse)', async () => {
  const { h, quits } = make(); const { c, after } = ctx();
  assert.deepEqual(await h.shutdown({}, c), { shuttingDown: true });
  assert.deepEqual(quits, []); after.forEach(f => f());
  assert.deepEqual(quits, ['shutdown-command']);
});
