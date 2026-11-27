'use strict';
// ECS bridge command handlers. Electron objects arrive through `ctx`, so this module is testable with stubs.
// Everything here is read-only against Spotify's page: no clicks, no input injection, no request modification.
const { PROTOCOL_VERSION, BridgeError } = require('./bridge.cjs');

function withTimeout(promise, ms, code) {
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new BridgeError(code, 'Timed out reading runtime state')), ms); });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
const clip = (v, max = 200) => (typeof v === 'string' ? v.slice(0, max) : null);
const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const ranged = (value, min, max) => {
  const n = num(value);
  return n !== null && n >= min && n <= max ? n : null;
};

function artworkURL(value) {
  if (typeof value !== 'string' || value.length > 256) return null;
  return /^https:\/\/i\.scdn\.co\/image\/[a-zA-Z0-9]+$/.test(value) ? value : null;
}

function canSetMuted(wc) {
  return typeof wc.setAudioMuted === 'function' && typeof wc.isAudioMuted === 'function';
}

function unsupportedPlayback(validate) {
  return async args => {
    if (!validate(args)) throw new BridgeError('invalid_args', 'Invalid playback arguments');
    throw new BridgeError('unsupported_action', 'Use the Spotify window for this action');
  };
}

const noArgs = args => Object.keys(args).length === 0;
const singleArg = (args, key, valid) => Object.keys(args).length === 1 && valid(args[key]);

// Runs in Spotify's page (main world, read-only). Its output is untrusted input and is re-validated below.
const PLAYBACK_PROBE = `(() => {
  const ms = navigator.mediaSession;
  const md = ms && ms.metadata;
  const els = [...document.querySelectorAll('audio,video')];
  const active = els.filter(m => !m.paused && !m.ended);
  const el = active.length === 1 ? active[0] : els.length === 1 ? els[0] : null;
  return {
    mediaSession: ms ? { playbackState: ms.playbackState, title: md ? md.title : null, artist: md ? md.artist : null, album: md ? md.album : null, artwork: md ? md.artwork.slice(0, 8).map(a => a.src) : [] } : null,
    element: el ? { paused: el.paused, ended: el.ended, currentTime: el.currentTime, duration: el.duration, readyState: el.readyState, muted: el.muted, volume: el.volume } : null,
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

    'playback.state': async () => {
      const wc = ctx.getWebContents();
      if (!wc) return { available: false, reason: 'not_ready' };
      const frame = wc.mainFrame;
      const onSpotify = () => !wc.isDestroyed() && wc.mainFrame === frame && ctx.trusted(frame?.url);
      if (!onSpotify()) return { available: false, reason: 'page_not_spotify_player' };

      let page;
      try {
        page = await withTimeout(frame.executeJavaScript(PLAYBACK_PROBE), 2000, 'playback_timeout');
      } catch (e) {
        if (e instanceof BridgeError) throw e;
        return { available: false, reason: 'probe_failed' };
      }
      if (!onSpotify()) return { available: false, reason: 'page_not_spotify_player' };

      const metadata = page?.mediaSession;
      const ms = metadata && typeof metadata === 'object' ? {
        playbackState: ['playing', 'paused', 'none'].includes(metadata.playbackState) ? metadata.playbackState : 'none',
        title: clip(metadata.title), artist: clip(metadata.artist), album: clip(metadata.album),
        artworkURL: Array.isArray(metadata.artwork) ? metadata.artwork.slice(0, 8).map(artworkURL).find(Boolean) ?? null : null
      } : null;
      const media = page?.element;
      const el = media && typeof media.paused === 'boolean' && typeof media.ended === 'boolean' ? {
        paused: media.paused, ended: media.ended, currentTimeSec: ranged(media.currentTime, 0, Infinity),
        durationSec: ranged(media.duration, Number.MIN_VALUE, Infinity), readyState: ranged(media.readyState, 0, 4),
        muted: typeof media.muted === 'boolean' ? media.muted : null, volume: ranged(media.volume, 0, 1)
      } : null;
      const audible = wc.isCurrentlyAudible();
      let status = ms?.title ? 'unknown' : 'idle';
      if (audible) status = 'playing';
      else if (el && !el.paused && !el.ended) status = el.readyState !== null && el.readyState < 3 ? 'buffering' : 'playing';
      else if (ms?.playbackState === 'playing') status = 'playing';
      else if (ms?.playbackState === 'paused' || (el?.paused && !el.ended && el.currentTimeSec > 0)) status = 'paused';
      return {
        available: true, status, audible, muted: wc.isAudioMuted(), mediaSession: ms, element: el,
        elementCount: ranged(page?.elementCount, 0, Infinity), itemKind: null,
        capabilities: {
          canPlay: false, canPause: false, canSkipNext: false, canSkipPrevious: false, canSeek: false, canSetVolume: false,
          canSetMuted: canSetMuted(wc), positionAvailable: el?.currentTimeSec != null, durationAvailable: el?.durationSec != null
        }
      };
    },

    'playback.play': unsupportedPlayback(noArgs),
    'playback.pause': unsupportedPlayback(noArgs),
    'playback.toggle': unsupportedPlayback(noArgs),
    'playback.next': unsupportedPlayback(noArgs),
    'playback.previous': unsupportedPlayback(noArgs),
    'playback.seek': unsupportedPlayback(args => singleArg(args, 'positionSec', v => ranged(v, 0, Infinity) !== null)),
    'playback.setVolume': unsupportedPlayback(args => singleArg(args, 'volume', v => ranged(v, 0, 1) !== null)),

    'playback.setMuted': async args => {
      if (!singleArg(args, 'muted', v => typeof v === 'boolean')) {
        throw new BridgeError('invalid_args', 'Expected one boolean muted argument');
      }
      const wc = ctx.getWebContents();
      if (!wc || wc.isDestroyed() || !ctx.trusted(wc.mainFrame?.url)) {
        throw new BridgeError('playback_unavailable', 'The Spotify player is unavailable');
      }
      if (!canSetMuted(wc)) throw new BridgeError('unsupported_action', 'Runtime output mute is unavailable');
      wc.setAudioMuted(args.muted);
      const muted = wc.isAudioMuted();
      if (muted !== args.muted) throw new BridgeError('mute_not_applied', 'Runtime output mute did not change');
      return { muted };
    },

    shutdown: async (_args, c) => {
      c.afterResponse(() => ctx.requestQuit('shutdown-command'));
      return { shuttingDown: true };
    }
  };
}

module.exports = { createHandlers };
