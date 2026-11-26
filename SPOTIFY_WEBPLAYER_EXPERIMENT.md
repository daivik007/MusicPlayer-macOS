# Spotify Web Player experiment

Branch: experiment/spotify-webplayer. Based on merged M3; the separate OAuth branch and PR #3 remain unchanged. No developer credentials or Premium subscription are required by this implementation.

## Test locally
1. Build on macOS with Xcode and run. Confirm local library and shuffle still work.
2. Click Spotify Web Player in the main window. Verify open.spotify.com loads.
3. Sign in on Spotify's actual page using a free account. If an external identity-provider popup fails, try Spotify's own login method if available. Do not enter credentials outside Spotify's trusted pages.
4. Open Your Library, a playlist, and Liked Songs inside the web player; check whether the UI works.
5. Click Play using Spotify's controls. Listen for actual audio for at least a minute; check pause, next, and any normal ads. Record exact Spotify error text if playback fails.
6. Close the Spotify window; confirm web audio stops. Reopen and verify login.
7. Quit the entire app, relaunch and reopen Spotify; check session persistence.
8. Clear Session and verify login is required again. Local music must remain unaffected.
9. If Spotify reports unsupported browser or protected-media errors, record macOS version and message. Compare with Spotify in Safari on the same machine.

## Limits
This is a feasibility test, not a native Spotify provider. WebKit's protected playback capability and Spotify's embedded-browser restrictions are unknown until tested. Login may work while playback fails. No user-agent spoofing, credential extraction, injected private-service bridges, DRM workarounds, or ad blocking. Normal Spotify subscription rules apply. Browser fallback does not share its session with the embedded player. No native library synchronization yet. No compilation or live playback was possible remotely.

## Playback diagnostic update
User verified free-account sign-in and library visibility, but clicking Play produces no audio. The experiment now permits asynchronous media startup (no WebKit gesture requirement) and exposes a Diagnostics sheet with standard EME, codec, MediaSource and media-element state checks. The EME queries request capability only; they do not request licenses. A rejected test configuration does not prove the key system is absent. Media elements in inaccessible frames or Web Audio pipelines may not appear. Debug builds allow Safari Web Inspector: enable web developer features in Safari settings, then use Develop and select the app's web view. Do not share raw network logs, tokens, cookies, or request headers. Test playback again before opening Diagnostics; copy the report and record whether Spotify in Safari plays on the same Mac. No DRM, user-agent or ad handling changes.
