# Chromium feasibility experiment — 2026-11-27

Based on merged M3, preserving PR #3 (OAuth) and PR #4 (WebKit). User verified free-account Spotify login/library in WKWebView, but playback failed. Desktop preference did not change the mobile bundle hint. Safari plays on the same machine/account/network. FairPlay probes accepted configurations; this does not prove successful license acquisition. No browser identification spoofing, ad modification, or DRM changes are planned.

## Research
- CEF official ARM64 distributions: https://cef-builds.spotifycdn.com/index.html
- Native Apple Silicon builds since M93: https://github.com/chromiumembedded/cef/blob/master/docs/master_build_quick_start.md
- CEF tutorial and cefclient URL flag: https://github.com/chromiumembedded/cef/blob/master/docs/tutorial.md
- CEF signing and sandbox: https://chromiumembedded.github.io/cef/code_signing.html and https://chromiumembedded.github.io/cef/sandbox_setup
- Google lists CEF/Electron as supported Widevine platforms: https://developers.google.com/widevine/drm/overview
- Google Widevine licensing/access: https://developers.google.com/widevine/access
- CEF Widevine integration limitations: https://github.com/chromiumembedded/cef/issues/3820
- Castlabs ECS and VMP: https://github.com/castlabs/electron-releases and https://castlabs.com/security/widevine-certification/
- Spotify supported browsers: https://support.spotify.com/us/article/web-player-help/

CEF binaries exist for macOS ARM64, but binary availability does not establish Widevine inclusion, codec availability, CDM redistribution rights or Spotify acceptance. VMP and provider license policies may affect playback. The CDN hosting relationship does not constitute Spotify authorization. No CDM is bundled here. Do not copy CDMs from other applications or disable security checks.

## Phase A — supported Chrome baseline
Build/run the native app on macOS. Click Spotify · Chrome Test. This pauses local playback and opens installed Google Chrome using Launch Services. No custom arguments, automation, access to Chrome profile, or developer credentials. Sign in via the browser, play a track for 60 seconds, test pause/next and normal ads. Verify session persistence. Chrome is external and not a playback provider. If Chrome is missing, obtain it from https://www.google.com/chrome/ or skip this baseline if you do not wish to install it.

## Phase B — standalone CEF client
1. Visit the official CEF builds page above. Under macOS ARM64 select a current stable Client Distribution (sample app), not Standard Distribution (SDK). If no client is offered, use the Standard Distribution and official CEF tutorial to build the sample; stop if the required build/security setup is unavailable.
2. Verify the published checksum before extracting. Keep the whole distribution together. Locate cefclient.app.
3. From the MusicPlayer repository run:
   bash experiments/chromium/check-cef.sh "/absolute/path/to/cefclient.app"
   The script checks executable architecture, lists helper bundles, checks signature and prints a launch command. It does not launch or install anything.
4. If the app can be opened normally under macOS security policy, run:
   open "/absolute/path/to/cefclient.app" --args --url=https://open.spotify.com/
   Stop if Gatekeeper blocks it; do not disable security protections. If cefclient is already running, quit it first.
5. Check whether Spotify's desktop web player loads and free-account login is possible. Test actual playback, including standard ads. Use only the site's own controls.
6. If playback fails, report the visible error, client version and whether Chrome plays. Do not share credentials, tokens, cookies or raw network logs.
7. Check Activity Monitor for aggregate browser/helper memory during playback and after closing; compare with Chrome and the native app. Do not infer engine-wide efficiency from a single run.

## Decision gates
- Chrome passes, CEF passes: investigate native Objective-C++ bridge and sandboxed helpers. Verify redistribution and signing requirements before packaging.
- Chrome passes, CEF fails: identify missing supported media capabilities, then consider licensed Widevine integration or ECS as a separately scoped prototype.
- Both fail: investigate browser/network/account baseline first.
- Do not merge a browser backend until native build, playback, resource usage, security, and distribution feasibility are validated.
- Keep local AVFoundation playback independent. No subscription required to run these tests; Spotify account/service restrictions still apply.

This commit implements a supported-browser launcher plus a standalone CEF inspection harness, not an embedded CEF engine. No CEF binary, signing changes, DRM integration, native library sync, or actual playback tests are included. The eventual CEF bridge needs C++ wrapper, framework, helpers, lifecycle and code signing; defer until test results justify it.
