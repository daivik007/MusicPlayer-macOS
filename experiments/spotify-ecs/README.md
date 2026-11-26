# Spotify ECS runtime

Independent Electron runtime (Castlabs ECS `45.2.1+wvcus`, Chromium 156) that plays Spotify's own web player with Widevine and AAC. **Spotify audio playback is confirmed working** (M4A). Since M4B it can be driven by the native app over stdio. Not a shipping backend; no ad, DRM or authentication changes.

## Root cause of the earlier silence
Spotify serves the mobile web-player bundle (which builds no media player and registers no service worker) when the User-Agent carries app/Electron tokens. With a plain Chromium UA it serves the desktop bundle and playback works. Client Hints were already identical to Chrome. The fix is the opt-in `--clean-ua` flag; no Client Hints, headers, ads or DRM are modified.

## Run (Apple Silicon)
```sh
cd experiments/spotify-ecs
npm install
npm run check                 # syntax checks + unit tests (permission policy, bridge protocol, handlers)
npm run start:clean-ua        # working configuration, persistent session
npm run start:fresh-clean-ua  # clean UA, in-memory session (log in each time)
npm run start:bridge          # same as clean UA, plus the stdio bridge (see below)
npm start                     # Electron's default UA: Spotify serves the mobile bundle, no playback
```
Log in with Spotify's own form. Diagnostics: Experiment > Run Capability Diagnostics (Cmd+Shift+D) prints a sanitized report on the terminal; check `uaMode` is `clean-chromium` and `bundleHints.desktop`/`generic` is true. Profile: `~/Library/Application Support/MusicPlayer-ECS-Experiment` (independent of any browser profile; delete it while ECS is closed to reset).

## M4B: stdio bridge (`--bridge`)
Newline-delimited JSON, UTF-8. **stdout carries only protocol lines**; everything else (including `console.log`) is rerouted to stderr. No sockets or HTTP.

```
request   {"v":1,"id":"<1-64 chars>","cmd":"ping","args":{}}
response  {"v":1,"id":"<same>","ok":true,"result":{...}}
          {"v":1,"id":"<same>|null","ok":false,"error":{"code":"...","message":"..."}}
event     {"v":1,"event":"runtime.ready","data":{...}}          (no id)
```
Responses may arrive out of order; match by `id`. Lines over 64k chars are rejected. Error codes: `invalid_json`, `invalid_request`, `unsupported_version`, `unknown_command`, `line_too_long`, `handler_timeout`, `internal_error`, plus per-command codes.

| Command | Result |
|---|---|
| `ping` | `{pong, time}` |
| `runtime.status` | `{protocol, pid, ready, uptimeMs, versions, sessionMode, uaMode, window, page:{trusted, loading, loginPage}}` |
| `auth.status` | `{state: signed-in\|signed-out\|unknown, basis, verified:false, loginPage}` |
| `playback.state` | `{available, status: playing\|paused\|idle, audible, muted, mediaSession:{playbackState,title,artist,album}, element:{paused,ended,currentTimeSec,durationSec,...}}` |
| `shutdown` | `{shuttingDown:true}`, then the runtime exits 0 |

Events: `runtime.starting` (bridge up, components pending), `runtime.ready` (Spotify document loaded), `runtime.error` (`duplicate_instance`, `startup_failed`), `runtime.exiting {reason}`, `playback.changed`, `auth.changed {state}`.

Lifecycle: stdin EOF (parent died), SIGTERM/SIGINT or closing the window all quit the runtime, so no orphan is left. A second runtime on the same profile emits `runtime.error duplicate_instance` and exits 73 (single-instance lock, bridge mode only). `shutdown` drops commands still in flight.

### What is and is not reliable
- `auth.status` is a heuristic: presence of Spotify's own `sp_dc` cookie (value never read out). A server-side revoked session is not detected. No supported auth API exists in the web player.
- `playback.state` reads `navigator.mediaSession`, the page's media element and Chromium audibility, read-only. Title/artist/position depend on Spotify's page and may be missing; treat them as best effort. **There are no playback control commands** (play/pause/seek/next); the only control surface is Spotify's UI, and automating it is out of scope.
- The window stays visible; it is needed to log in.

## Native side (SwiftUI app)
`MusicPlayer/ECS/` (auto-included by the Xcode synchronized folder): `ECSProtocol.swift` (wire/typed models, configuration), `ECSRuntime.swift` (`actor` owning the `Process`: start/ready/timeouts/crash/stop/duplicate guard), `ECSDebugSmoke.swift` (DEBUG only). No UI or local-playback code changed.

```swift
let runtime = ECSRuntime(configuration: .development(appDirectory: ecsURL))  // adds --bridge --clean-ua
try await runtime.start()                 // returns at runtime.ready
let auth = try await runtime.authStatus()
let play = try await runtime.playbackState()
await runtime.stop()                      // shutdown command -> SIGTERM -> SIGKILL
```
### Sandbox (blocking for local runs)
The app currently has **App Sandbox enabled**. A sandboxed app cannot launch an unsigned external Electron binary or read this folder, so `start()` will fail. For development, turn App Sandbox off for the Debug configuration (Xcode: target > Signing & Capabilities > remove App Sandbox, or `ENABLE_APP_SANDBOX = NO` in Debug). This was deliberately not changed here. Shipping would need a signed, bundled runtime with the inherit entitlement, or a different architecture.

## Tests
- `npm run check`: syntax + 22 unit tests, including real child-process tests of the stdout/stderr split, malformed input, oversize lines and EOF shutdown.
- `npm run smoke` (real Electron, needs macOS): ping/status, malformed input, duplicate refusal, `kill -9` crash, restart, session persistence, clean shutdown. Options: `--login-wait 180`, `--watch-playback 15` (start a track and it checks audible + advancing position), `--expect-signed-in`, `--fresh`.
- Swift end-to-end: run the app from Xcode (sandbox off) with env `MUSICPLAYER_ECS_SMOKE_DIR=<abs path to experiments/spotify-ecs>`; watch `[ECS smoke]` lines.

## Limits
Spotify can change bundle selection server-side; keep the `bundleHints` check. Wrapping Spotify's web player may conflict with its terms; this is a personal experiment, and the official route is the Web Playback SDK (Premium). Electron adds several hundred MB. Production VMP signing and distribution are unreviewed.
