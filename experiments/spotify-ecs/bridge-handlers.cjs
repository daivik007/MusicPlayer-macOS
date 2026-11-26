'use strict';
// M4B: command handlers. Electron objects arrive through `ctx`, so this module is testable with stubs.
// Everything here is read-only against Spotify's page: no clicks, no input injection, no request modification.
const { PROTOCOL_VERSION, BridgeError } = require('./bridge.cjs');

function withTimeout(promise, ms, code) {
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new BridgeError(code, 'Timed out reading runtime state')), ms); });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
const clip = (v, max = 200) => (typeof v === 'string' ? v.slice(0, max) : null);
const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : null);

// Runs in Spotify's page (main world, read-only). Its output is untrusted input and is re-validated below.
const PLAYBACK_PROBE = `(() => {
  const ms = navigator.mediaSession;
  const md = ms && ms.metadata;
  const els = [...document.querySelectorAll('audio,video')];
  const el = els.find(m => !m.paused) || els[0] || null;
  return {
    mediaSession: ms ? { playbackState: ms.playbackState, title: md ? md.title : null, artist: md ? md.artist : null, album: md ? md.album : null } : null,
    element: el ? { paused: el.paused, ended: el.ended, currentTime: el.currentTime, duration: el.duration, readyState: el.readyState, muted: el.muted } : null,
    elementCount: els.length
  };
})()`;

function hostOf(url) { try { return new URL(url).hostname; } catch { return ''; } }

function createHandlers(ctx) {
  return {
    ping: async () => ({ pong: true, time: ctx.now() }),

    'runtime.status': async () => {
      const wc = ctx.getWebContents();
      const url = wc ? wc.getURL() : '';
      return {
        protocol: PROTOCOL_VERSION,
        pid: ctx.pid,
        ready: ctx.isReady(),
        uptimeMs: ctx.now() - ctx.startedAtMs,
        versions: ctx.versions,
        sessionMode: ctx.config.sessionMode,
        uaMode: ctx.config.uaMode,
        window: !!wc,
        page: wc ? { trusted: ctx.trusted(url), loading: wc.isLoading(), loginPage: hostOf(url) === 'accounts.spotify.com' } : null
      };
    },

    // No supported Spotify auth API exists in a web player. Basis is the presence of Spotify's own login cookie
    // (name only; value is never read out or returned). It is a heuristic: a revoked or expired server-side session is not detected.
    'auth.status': async () => {
      const wc = ctx.getWebContents();
      if (!wc) return { state: 'unknown', reason: 'not_ready', verified: false };
      const loginPage = hostOf(wc.getURL()) === 'accounts.spotify.com';
      let cookies;
      try { cookies = await withTimeout(wc.session.cookies.get({ name: 'sp_dc' }), 3000, 'auth_timeout'); }
      catch { return { state: 'unknown', reason: 'cookie_query_failed', verified: false, loginPage }; }
      const nowSec = ctx.now() / 1000;
      const present = cookies.some(c => /(^|\.)spotify\.com$/.test(String(c.domain || '').replace(/^\./, '')) &&
        typeof c.value === 'string' && c.value.length > 0 && (c.expirationDate === undefined || c.expirationDate > nowSec));
      return { state: present ? 'signed-in' : 'signed-out', basis: 'sp_dc_cookie_presence', verified: false, loginPage };
    },

    // Sources: webContents audibility (Chromium) + navigator.mediaSession + the page's media element, all read-only.
    // Position/duration come from the element and may be absent depending on how Spotify's player is built.
    'playback.state': async () => {
      const wc = ctx.getWebContents();
      if (!wc) return { available: false, reason: 'not_ready' };
      if (!ctx.trusted(wc.getURL())) return { available: false, reason: 'page_not_spotify_player' };
      let page;
      try { page = await withTimeout(wc.executeJavaScript(PLAYBACK_PROBE), 2000, 'playback_timeout'); }
      catch (e) { if (e instanceof BridgeError) throw e; return { available: false, reason: 'probe_failed' }; }
      const ms = page && page.mediaSession ? {
        playbackState: ['playing', 'paused', 'none'].includes(page.mediaSession.playbackState) ? page.mediaSession.playbackState : 'none',
        title: clip(page.mediaSession.title), artist: clip(page.mediaSession.artist), album: clip(page.mediaSession.album)
      } : null;
      const el = page && page.element ? {
        paused: !!page.element.paused, ended: !!page.element.ended, currentTimeSec: num(page.element.currentTime),
        durationSec: num(page.element.duration), readyState: num(page.element.readyState), muted: !!page.element.muted
      } : null;
      const audible = wc.isCurrentlyAudible();
      let status = 'idle';
      if (audible || (el && !el.paused && !el.ended) || (ms && ms.playbackState === 'playing')) status = 'playing';
      else if ((ms && ms.playbackState === 'paused') || (el && el.paused && el.currentTimeSec > 0)) status = 'paused';
      return { available: true, status, audible, muted: wc.isAudioMuted(), mediaSession: ms, element: el, elementCount: num(page && page.elementCount) };
    },

    shutdown: async (_args, c) => {
      c.afterResponse(() => ctx.requestQuit('shutdown-command'));
      return { shuttingDown: true };
    }
  };
}

module.exports = { createHandlers };
