# Development roadmap

- [x] M1: Local playback, seeking, metadata and artwork (user-tested).
- [x] M2: Multi-file import, in-memory library, queue, previous/next, shuffle and repeat (user-tested and merged).
- [x] M3: Persistent library, security-scoped bookmarks, settings (user-tested and merged).
- [ ] M4: Spotify feasibility — OAuth and WebKit branches retained; Chromium/CEF baseline experiment in review.
- [ ] M5: YouTube Music integration feasibility; official API limitations.
- [ ] M6: Permissioned extension SDK and isolated runtime.
- [ ] M7: Authorized remote FLAC playback and cache.
- [ ] M8: Timed lyrics and word-level rendering.
- [ ] M9: Apple Music-inspired native interface.
- [ ] M10: Media keys, mini player, accessibility.
- [ ] M11: Release, notarization and testing.

Each milestone uses a feature branch and a reviewed PR. Build and test on macOS before merging. Service integrations must respect provider authorization and policies.
