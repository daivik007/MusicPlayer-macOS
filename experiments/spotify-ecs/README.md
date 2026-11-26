# Spotify ECS experiment

Independent feasibility test, based on main. Native SwiftUI source, Xcode project, local playback and persistence remain unchanged. Prior OAuth, WebKit and CEF experiments remain on their own branches.

## Run on Apple Silicon
Install a supported Node.js LTS and npm if absent (Homebrew: brew install node). From repository root:

```sh
cd experiments/spotify-ecs
npm install
npm run check
npm start
```

Pinned Castlabs ECS v45.2.1+wvcus, official GitHub distribution. No CDM copied from browsers; ECS initializes its component via components.whenReady before the browser is opened. First launch requires network. A package lock is generated locally; not yet verified or committed. If initialization fails, capture the terminal error (redact sensitive information); do not bypass signing or sandbox protections.

Login directly using Spotify's own login form. External identity provider popups may be blocked by the navigation policy. Test track playback for 60 seconds, seek, pause/resume and next track using Spotify UI, with normal ads. Menu Experiment > Run Capability Diagnostics (Cmd+Shift+D) prints a sanitized report in terminal. Report AAC and Widevine results and whether seekbar advances and audio is audible. No raw request logging, cookies or tokens collected. DevTools optional; redact credentials.

The profile is independent in ~/Library/Application Support/MusicPlayer-ECS-Experiment. No existing browser profile is accessed. Quit ECS after testing. To reset, use Spotify logout; removing that directory while ECS is closed deletes its session and component data.

## Limits
Development VMP signatures may not be accepted by Spotify production license servers; successful capability tests do not prove actual playback. Production signing, authorization and distribution feasibility require separate review. No ad modification, UA spoofing, native playback bridge, library sync or binary distribution. This is not a shipping backend. No subscription or Spotify developer credentials needed for the test itself. Runtime install and playback must be tested on macOS.

Sources:
- https://github.com/castlabs/electron-releases
- https://github.com/castlabs/electron-releases/releases/tag/v45.2.1+wvcus
- https://www.electronjs.org/docs/latest/tutorial/security

CEF baseline: user-built ARM64 sample launched, Spotify showed playing but seekbar stalled. AAC capability empty; Widevine AAC rejected, Opus and VP9 accepted. Safari and Phi played normally. ECS tests whether a different media stack helps; exact cause remains unverified.
