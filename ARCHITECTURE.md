# Architecture

Native macOS SwiftUI application. The present milestone keeps AVAudioPlayer for local playback. ContentView owns the engine and library; LibraryManager owns import and playback order, Track owns local URL and metadata, MetadataManager extracts tags and technical information. AudioEngine reports successful completion via a callback, avoiding a dependency on library state.

M2 is intentionally session-only. The sandbox remains enabled with user-selected read access; M3 will add persistent security-scoped bookmarks and storage. No remote providers or credentials are implemented yet. The extension system will need explicit permission boundaries, isolated execution and a documented API. Provider library access must be separated from authorized playback, and audio quality must be based on actual source/output properties rather than filenames.

## M2 acceptance tests
- Import three local audio files, check artwork and metadata, reimport and verify deduplication.
- Select a track, seek, pause/resume, use next and previous.
- Finish a track: advance automatically; at the final track repeat off stops, all wraps, one repeats.
- Toggle shuffle and verify upcoming order changes without interrupting current playback.
- Import additional tracks during playback and verify they become available.
- Test an invalid or unavailable file; verify a visible error.
- Relaunch: session library clears by design.
- Run on macOS in Xcode. Native build and playback have not been verified remotely.
