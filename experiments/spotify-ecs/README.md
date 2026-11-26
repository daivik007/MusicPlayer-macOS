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

### Authentication and playback status

- `auth.status` uses the presence of a nonempty, unexpired Spotify login cookie as a heuristic. The bridge returns `verified: false` and keeps cookie values out of messages.
- On the tested Apple Silicon Mac, Spotify audio played through the independent runtime, including advertisements. Chromium reported audibility and MediaSession exposed track titles. The probe found zero document media elements during songs and ads, so position and duration were unavailable. MediaSession reported playback state `none` in those samples.
- The Electron window provides the Spotify playback and login UI. Supported playback controls and reliable position and duration remain open for M4C investigation.

## Native side (SwiftUI app)
`MusicPlayer/ECS/` (auto-included by the Xcode synchronized folder): `ECSProtocol.swift` (wire/typed models, configuration), `ECSRuntime.swift` (`actor` owning the `Process`: start/ready/timeouts/crash/stop/duplicate guard), `ECSDebugSmoke.swift` (DEBUG only). No UI or local-playback code changed.

```swift
let runtime = ECSRuntime(configuration: .development(appDirectory: ecsURL))  // adds --bridge --clean-ua
try await runtime.start()                 // returns at runtime.ready
let auth = try await runtime.authStatus()
let play = try await runtime.playbackState()
await runtime.stop()                      // shutdown command -> SIGTERM -> SIGKILL
```

### Debug smoke build on macOS

The regular Debug and Release builds use App Sandbox and the checked-in entitlements. Launching the repository's Electron executable requires a separate Debug build with App Sandbox disabled. Clear `CODE_SIGN_ENTITLEMENTS` for this build because `MusicPlayer.entitlements` also explicitly enables the sandbox. Run from the repository root with Xcode and a macOS SDK that supports the project's macOS 27 deployment target.

```sh
repo="$PWD"
(cd "$repo/experiments/spotify-ecs" && npm install)
xcodebuild -list -project MusicPlayer.xcodeproj
smoke_build=$(mktemp -d)
xcodebuild -project MusicPlayer.xcodeproj -scheme MusicPlayer -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$smoke_build" \
  ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS= ENABLE_USER_SELECTED_FILES= build
app="$smoke_build/Build/Products/Debug/MusicPlayer.app"
codesign -d --entitlements :- "$app"
MUSICPLAYER_ECS_SMOKE_DIR="$repo/experiments/spotify-ecs" "$app/Contents/MacOS/MusicPlayer"
```

Check the signed entitlements for absence of `com.apple.security.app-sandbox` before launching. Close any existing ECS window first so the smoke test can use the persistent profile. Watch for `[ECS smoke] done, 0 failure(s)`. The smoke build runs outside the normal app container. Use the regular sandboxed build for the local FLAC and library persistence checks in `ARCHITECTURE.md`.

## Tests

- `npm run check` runs syntax checks and 22 Node tests, including real child-process checks for stdout/stderr separation, malformed input and stdin EOF.
- The Swift lifecycle tests exercise a Node fixture over real pipes without launching Spotify. From the repository root on macOS, run:

  ```sh
  test_build=$(mktemp -d)
  xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature MemberImportVisibility -D DEBUG \
    MusicPlayer/ECS/*.swift experiments/spotify-ecs/native-runtime.test.swift \
    -o "$test_build/ecs-runtime-tests"
  "$test_build/ecs-runtime-tests" "$(command -v node)" \
    "$PWD/experiments/spotify-ecs/bridge-test-host.cjs"
  ```

- `npm run smoke` exercises real Electron on macOS. Prior runs verified bridge readiness, commands, duplicate-instance refusal, crash recovery, cookie retention and clean shutdown. The optional `--watch-playback` assertion still requires both audibility and advancing position. It failed in the prior Spotify runs because the probe had no position samples.

## Limits
Spotify can change bundle selection server-side; keep the `bundleHints` check. Wrapping Spotify's web player may conflict with its terms; this is a personal experiment, and the official route is the Web Playback SDK (Premium). Electron adds several hundred MB. Production VMP signing and distribution are unreviewed.
