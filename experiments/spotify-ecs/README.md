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
| `playback.state` | `{available, reason?, status?, audible?, muted?, mediaSession?, element?, elementCount?, itemKind?, capabilities?}` |
| `playback.setMuted` | Accepts `{muted: boolean}`. Returns the observed runtime mute state as `{muted: boolean}`. |
| `playback.play`, `playback.pause`, `playback.toggle`, `playback.next`, `playback.previous` | Expect no arguments. Return `unsupported_action`. |
| `playback.seek`, `playback.setVolume` | Expect `{positionSec: nonnegative number}` or `{volume: number in 0...1}`. Return `unsupported_action`. |
| `shutdown` | `{shuttingDown:true}`, then the runtime exits 0 |

Events: `runtime.starting` (bridge up, components pending), `runtime.ready` (Spotify document loaded), `runtime.error` (`duplicate_instance`, `startup_failed`), `runtime.exiting {reason}`, `playback.changed`, `auth.changed {state}`.

Lifecycle: stdin EOF (parent died), SIGTERM/SIGINT or closing the window all quit the runtime, so no orphan is left. A second runtime on the same profile emits `runtime.error duplicate_instance` and exits 73 (single-instance lock, bridge mode only). `shutdown` drops commands still in flight.

### Playback schema and interfaces

- `status` is `playing`, `paused`, `buffering`, `idle` or `unknown`. It uses Chromium audibility, MediaSession playback state and an unambiguous document media element where available. A silent player with metadata and no affirmative state signal reports `unknown`.
- `mediaSession` can contain `playbackState`, `title`, `artist`, `album` and `artworkURL`. Artwork accepts only clean HTTPS image URLs from `i.scdn.co`. The Swift view loads artwork from that URL. Missing or unexpected artwork uses a placeholder.
- `element` can contain `paused`, `ended`, `currentTimeSec`, `durationSec`, `readyState`, `muted` and `volume`. The last two fields describe the page element. Top-level `muted` describes Electron output mute. Position and duration are absent when the probe has no suitable element. `itemKind` remains null because the probe has no reliable music or advertisement marker.
- `capabilities` reports `canPlay`, `canPause`, `canSkipNext`, `canSkipPrevious`, `canSeek`, `canSetVolume`, `canSetMuted`, `positionAvailable` and `durationAvailable`. Availability and output mute are evaluated from the current state and trusted frame. The transport and numeric volume flags are false for the current integration. Missing capabilities disable native actions.
- `playback.setMuted` validates input and requires a trusted Spotify player and Electron mute support. Malformed arguments return `invalid_args`, a missing or untrusted player returns `playback_unavailable`, and an unconfirmed mute state returns `mute_not_applied`. Known unsupported commands validate arguments and return `unsupported_action` for valid requests.
- The public Media Session API exposes metadata and lets a page register its own action handlers and set position state. It exposes no position getter or method for the host to invoke a page's handlers. Electron's WebContents API supplies audibility, media events and window output mute. The existing DevTools Media trace reports diagnostic player events and properties and offers no supported transport or reliable position source for this Spotify session. The official Spotify Web Playback SDK requires Premium and would be a separate integration. [Media Session API](https://w3c.github.io/mediasession/) · [Electron WebContents](https://www.electronjs.org/docs/latest/api/web-contents) · [DevTools Media domain](https://chromedevtools.github.io/devtools-protocol/tot/Media/) · [Spotify Web Playback SDK](https://developer.spotify.com/documentation/web-playback-sdk)

### Authentication and playback status

- `auth.status` uses the presence of a nonempty, unexpired Spotify login cookie as a heuristic. The bridge returns `verified: false` and keeps cookie values out of messages.
- On the tested Apple Silicon Mac, Spotify audio played through the independent runtime, including advertisements. Chromium reported audibility and MediaSession exposed track titles. The probe found zero document media elements during songs and ads, so position and duration were unavailable. MediaSession reported playback state `none` in those samples.
- The Electron window provides Spotify transport, numeric volume and login. M4C adds native playback monitoring and Electron output mute.

## Native side (SwiftUI app)
`MusicPlayer/ECS/` (auto-included by the Xcode synchronized folder): `ECSProtocol.swift` (wire/typed models, configuration), `ECSRuntime.swift` (`actor` owning the `Process`: start/ready/timeouts/crash/stop/duplicate guard), `ECSDebugSmoke.swift` (DEBUG only). No UI or local-playback code changed.

```swift
let runtime = ECSRuntime(configuration: .development(appDirectory: ecsURL))  // adds --bridge --clean-ua
try await runtime.start()                 // returns at runtime.ready
let auth = try await runtime.authStatus()
let play = try await runtime.playbackState()
await runtime.stop()                      // shutdown command -> SIGTERM -> SIGKILL
```

### Debug build on macOS

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

### Run M4C and verify on Apple Silicon

From the repository root, build with the same Debug-only overrides above. Ensure the ECS experiment's dependencies are installed and quit any independently running ECS experiment first.

```sh
(
  set -e
  (cd experiments/spotify-ecs && npm install --package-lock=false)
  player_build=$(mktemp -d)
  xcodebuild -project MusicPlayer.xcodeproj -scheme MusicPlayer -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$player_build" \
    ENABLE_APP_SANDBOX=NO CODE_SIGN_ENTITLEMENTS= ENABLE_USER_SELECTED_FILES= build
  MUSICPLAYER_ECS_DIR="$PWD/experiments/spotify-ecs" \
    "$player_build/Build/Products/Debug/MusicPlayer.app/Contents/MacOS/MusicPlayer"
)
```

1. Start a local track, then select **Spotify** in the native app. Confirm local audio pauses, the native app stays responsive while connecting and the Electron window opens. Sign in using the Spotify window if needed.
2. Start playback in the Spotify window and confirm audible audio. Change tracks and pause/resume there. Check that track, artist, album, public artwork and status update where available. A silent item can show **Playback status unavailable** when the page provides no affirmative paused or playing signal.
3. Click **Mute Spotify Output** and **Unmute Spotify Output**. Confirm the audio responds and the Spotify track continues in its window. Check that progress appears only if measured and the app offers no native seek or skip for a restricted item. If an advertisement plays, verify it plays normally in Spotify's window.
4. Close the Electron window. Confirm the native snapshot clears. Click **Connect to Spotify**, confirm the existing Spotify session persists and check that the native view shows the current state again.
5. While Spotify is active, select **Return to Local Music**. Confirm the Spotify window closes before local controls return, and the local queue and position are available. Connect to Spotify again, quit MusicPlayer and confirm its Electron child closes. Run the regular sandboxed build separately and repeat the FLAC import, pause, seek, queue, shuffle, repeat and relaunch checks.

## Tests

At `2f283f4`, the Apple Silicon macOS Debug build succeeded, all five Swift fixture checks passed, and the native Electron smoke test finished with zero failures. Swift received readiness and command responses, rejected a second instance, recovered after a forced crash, observed the signed-in cookie state before and after restart, and shut down cleanly. Spotify was idle during the native smoke test. The local FLAC playback and persistence regression passed in the regular sandboxed build.

- `npm run check` passed all 27 Node tests for M4C, including playback arguments and capability handling, trusted frame checks, stdout/stderr separation and shutdown during a pending command.
- The M4C Swift fixture passed all six groups on Linux with Swift 6.2.3, including typed snapshots, observed state updates, output mute errors, provider switching and reconnection. The M4C Xcode build, native UI and real Spotify checks require Apple Silicon macOS verification. The macOS results above are for M4B.
- The Swift lifecycle tests exercise a Node fixture over real pipes without launching Spotify. From the repository root on macOS, run:

  ```sh
  test_build=$(mktemp -d)
  xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature MemberImportVisibility -D DEBUG \
    MusicPlayer/ECS/*.swift MusicPlayer/PlaybackController.swift \
    experiments/spotify-ecs/native-runtime.test.swift \
    -o "$test_build/ecs-runtime-tests"
  "$test_build/ecs-runtime-tests" "$(command -v node)" \
    "$PWD/experiments/spotify-ecs/bridge-test-host.cjs"
  ```

- `npm run smoke` exercises real Electron on macOS. Prior runs verified bridge readiness, commands, duplicate-instance refusal, crash recovery, cookie retention and clean shutdown. The optional `--watch-playback` assertion still requires both audibility and advancing position. It failed in the prior Spotify runs because the probe had no position samples.

## Limits
Spotify can change bundle selection server-side; keep the `bundleHints` check. Wrapping Spotify's web player may conflict with its terms; this is a personal experiment, and the official route is the Web Playback SDK (Premium). Electron adds several hundred MB. Production VMP signing and distribution are unreviewed.
