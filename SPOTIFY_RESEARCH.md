# Spotify integration research — November 2026

## Revera reference
Inspected the GitHub mirror at https://github.com/caruno-git/Revera (README, base/api-spotify/README.md, PageAuth.kt and WebPlayerHost.kt). Its login is a browser session on Spotify's sign-in page, with per-profile cookies and a web-player host. PageAuth observes authentication failures and signals stale sessions. The API module uses web-player services rather than the supported developer OAuth flow. The mirror states active development moved elsewhere; this review is of the mirror only. No Revera code was copied.

## Official API
- https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security
- https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide
- https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- https://developer.spotify.com/documentation/web-api/concepts/redirect_uri
- https://developer.spotify.com/policy
- https://developer.spotify.com/documentation/web-api/reference/get-users-saved-tracks
- https://developer.spotify.com/documentation/web-api/reference/get-a-list-of-current-users-playlists

Development Mode requires the app owner to have Premium, one new Client ID per developer and up to five authorized users. New apps have restricted endpoints; playlist contents are limited to owned or collaborative playlists. Public release and integration with other sources require review of Spotify terms, including restrictions on replacing its core experience. Do not treat this experiment as authorization for a public replacement client.

## Design
Read-only provider in a separate Settings screen. Browser OAuth PKCE with secure random state/verifier, a loopback-only HTTP callback, token refresh and Keychain persistence. No client secret, private web APIs, cookies, DRM manipulation, or Spotify audio extraction. Spotify links go back to the service. Metadata remains in memory and is cleared on disconnect. Local library is not modified. Playlist contents, provider protocol and unified sync are deferred until account access and policy feasibility are verified.

## Setup and acceptance
1. Create or reuse a permitted development app at https://developer.spotify.com/dashboard. App owner must have Premium; allowlist the test account if needed.
2. Register redirect URI exactly: http://127.0.0.1:43821/callback. Copy Client ID only, not Client Secret.
3. Build and run on macOS, open MusicPlayer Settings (Cmd+,), enter Client ID, Connect Spotify.
4. Browser consent should return to app. Verify profile, playlists, liked songs and links; individual endpoint errors remain visible.
5. Quit/relaunch, open Settings and verify Keychain restoration. Test refresh and Disconnect, denial and callback cancellation.
6. Confirm local playback/library still works. Port 43821 must be free. Test sandbox signing and Keychain behavior locally.
7. Disconnect clears the local token; to revoke Spotify's grant use Spotify account app permissions. Before distribution, publish required privacy disclosures and secure appropriate authorization.

No native build, real OAuth or API test was possible from chat. This is a limited proof of concept.
