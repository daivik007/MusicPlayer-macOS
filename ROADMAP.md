# Development roadmap

- [x] M1: Local playback, seeking, metadata and artwork (user-tested).
- [x] M2: Multi-file import, in-memory library, queue, previous/next, shuffle and repeat (user-tested and merged).
- [ ] M3: Persistent library, security-scoped bookmarks, settings (implementation in review).
- [ ] M4: Spotify OAuth/API feasibility and supported library access.
  - [x] M4A: Spotify playback in an independent ECS runtime (clean User-Agent).
  - [x] M4B: Swift–ECS stdio bridge (ping, runtime/auth/playback status, shutdown). macOS build, Swift lifecycle fixture, native Electron smoke test and sandboxed local playback regression passed.
  - [ ] M4C: Native Spotify monitoring, runtime output mute and provider switching implemented. macOS SwiftUI build and real Spotify verification remain pending. Transport and timeline capabilities depend on supported runtime interfaces.
- [ ] M5: YouTube Music integration feasibility; official API limitations.
- [ ] M6: Permissioned extension SDK and isolated runtime.
- [ ] M7: Authorized remote FLAC playback and cache.
- [ ] M8: Timed lyrics and word-level rendering.
- [ ] M9: Apple Music-inspired native interface.
- [ ] M10: Media keys, mini player, accessibility.
- [ ] M11: Release, notarization and testing.

Each milestone uses a feature branch and a reviewed PR. Build and test on macOS before merging. Service integrations must respect provider authorization and policies.
