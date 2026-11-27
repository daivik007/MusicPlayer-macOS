'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createHandlers } = require('./bridge-handlers.cjs');
const { trusted } = require('./permission-policy.cjs');

function make({ url = 'https://open.spotify.com/', cookies = [], probe, audible = false, noWindow = false, muteSupported = true, rejectMute = false } = {}) {
  const quits = [];
  let muted = false;
  const wc = { getURL: () => url, isLoading: () => false, isDestroyed: () => false,
    isCurrentlyAudible: () => audible, isAudioMuted: () => muted,
    mainFrame: { url, executeJavaScript: async () => probe }, session: { cookies: { get: async () => cookies } } };
  if (muteSupported) wc.setAudioMuted = value => { if (!rejectMute) muted = value; };
  const h = createHandlers({ pid: 42, startedAtMs: 1000, now: () => 5000, versions: { electron: 'e', chrome: 'c', node: 'n', app: 'a' },
    config: { sessionMode: 'persistent', uaMode: 'clean-chromium' }, getWebContents: () => (noWindow ? null : wc), isReady: () => true, trusted, requestQuit: r => quits.push(r) });
  return { h, quits, wc };
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
  assert.equal(r.element, null); assert.equal(r.elementCount, null);
});

test('playback state keeps missing position explicit and validates artwork, volume and capabilities', async () => {
  const cdn = 'https://i.scdn.co/image/abc123';
  const metadata = { title: 'Track', artwork: ['https://i.scdn.co.evil.test/image/abc', cdn + '?secret=x', cdn] };
  const probe = { mediaSession: metadata, element: null, elementCount: 0 };
  const state = await make({ probe, audible: true }).h['playback.state']();
  assert.equal(state.mediaSession.artworkURL, cdn);
  assert.equal(state.element, null);
  assert.equal(state.itemKind, null);
  assert.deepEqual(state.capabilities, {
    canPlay: false, canPause: false, canSkipNext: false, canSkipPrevious: false, canSeek: false, canSetVolume: false,
    canSetMuted: true, positionAvailable: false, durationAvailable: false
  });
  assert.deepEqual(JSON.parse(JSON.stringify(state)), state);
  probe.element = { paused: false, ended: false, currentTime: 0, duration: 99, readyState: 2, volume: 0.25 };
  const buffering = await make({ probe }).h['playback.state']();
  assert.equal(buffering.status, 'buffering');
  assert.equal(buffering.element.volume, 0.25);
  assert.equal(buffering.element.currentTimeSec, 0);
  assert.equal(buffering.capabilities.positionAvailable, true);
  assert.equal(buffering.capabilities.durationAvailable, true);

  probe.element = { paused: true, ended: false, currentTime: -1, duration: 0, volume: 2 };
  const unknown = await make({ probe, muteSupported: false }).h['playback.state']();
  assert.equal(unknown.status, 'unknown');
  assert.equal(unknown.element.volume, null);
  assert.equal(unknown.capabilities.positionAvailable, false);
  assert.equal(unknown.capabilities.durationAvailable, false);
  assert.equal(unknown.capabilities.canSetMuted, false);
});

test('playback state checks the committed frame before and after reading it', async () => {
  const { h, wc } = make();
  wc.mainFrame.url = 'https://example.com/';
  wc.mainFrame.executeJavaScript = () => assert.fail('untrusted frame must not be queried');
  assert.equal((await h['playback.state']()).reason, 'page_not_spotify_player');
  wc.mainFrame.url = 'https://open.spotify.com/';
  wc.mainFrame.executeJavaScript = async () => {
    wc.mainFrame = { url: 'https://accounts.spotify.com/' };
    return { mediaSession: { title: 'Discard after navigation' } };
  };
  assert.equal((await h['playback.state']()).reason, 'page_not_spotify_player');
});

test('output mute validates arguments, observes the result and requires an available trusted player', async () => {
  const { h, wc } = make();
  const mute = h['playback.setMuted'];
  for (const args of [{}, { muted: 1 }, { muted: 'false' }, { muted: false, extra: true }]) {
    await assert.rejects(mute(args), { code: 'invalid_args' });
  }
  assert.deepEqual(await mute({ muted: true }), { muted: true });
  assert.equal((await h['playback.state']()).muted, true);
  assert.deepEqual(await mute({ muted: false }), { muted: false });
  assert.equal(wc.isAudioMuted(), false);
  await assert.rejects(make({ noWindow: true }).h['playback.setMuted']({ muted: true }), { code: 'playback_unavailable' });
  await assert.rejects(make({ url: 'https://accounts.spotify.com/' }).h['playback.setMuted']({ muted: true }), { code: 'playback_unavailable' });
  await assert.rejects(make({ muteSupported: false }).h['playback.setMuted']({ muted: true }), { code: 'unsupported_action' });
  await assert.rejects(make({ rejectMute: true }).h['playback.setMuted']({ muted: true }), { code: 'mute_not_applied' });
});

test('transport and numeric volume reject malformed and unsupported requests', async () => {
  const { h } = make();
  for (const action of ['play', 'pause', 'toggle', 'next', 'previous']) {
    await assert.rejects(h[`playback.${action}`]({}), { code: 'unsupported_action' });
    await assert.rejects(h[`playback.${action}`]({ extra: true }), { code: 'invalid_args' });
  }
  await assert.rejects(h['playback.seek']({ positionSec: 10 }), { code: 'unsupported_action' });
  await assert.rejects(h['playback.seek']({ positionSec: -1 }), { code: 'invalid_args' });
  await assert.rejects(h['playback.setVolume']({ volume: 0.5 }), { code: 'unsupported_action' });
  await assert.rejects(h['playback.setVolume']({ volume: 1.5 }), { code: 'invalid_args' });
});

test('shutdown quits only after the response (afterResponse)', async () => {
  const { h, quits } = make(); const { c, after } = ctx();
  assert.deepEqual(await h.shutdown({}, c), { shuttingDown: true });
  assert.deepEqual(quits, []); after.forEach(f => f());
  assert.deepEqual(quits, ['shutdown-command']);
});
