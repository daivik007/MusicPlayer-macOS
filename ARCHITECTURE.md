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

## M3 persistent storage

LibraryStore uses a versioned JSON snapshot stored as one SQLite BLOB row in the app's Application Support directory. Single-statement upserts are atomic; this is a deliberately minimal schema, not yet a normalized catalog. A failed load disables writes to avoid overwriting an unreadable database. Saved metadata is minimal; artwork and technical metadata are refreshed on launch. The app retains security-scoped read-only bookmarks, refreshes stale ones and balances file access. The engine holds its own scope during playback. Unavailable rows are retained and can be located or removed via their context menu. A single main window prevents concurrent independent library writers.

State includes stable track IDs, queue order, shuffle/repeat, last track and position. Restore is paused; periodic checkpoints every five seconds and immediate saves after controls/import/removal/normal termination reduce lost state. No original audio is copied or deleted. A crash may lose the latest few seconds.

### M3 acceptance tests
- Import three FLAC files, select one, seek and set shuffle/repeat. Quit with Cmd+Q and relaunch; verify library, artwork, queue, settings and paused position.
- Confirm playback after relaunch with sandbox enabled. Test files outside the project folder.
- Move or rename a file; if bookmark cannot resolve, verify unavailable row, Locate File and recovery. Delete a test copy and confirm unavailable rows are not silently removed.
- Remove a track from the library, verify source file still exists, then relaunch and verify removal persists.
- Remove current track and check playback stops; test queue advancement and repeat again.
- Test a forced quit after a checkpoint; verify last saved position is restored approximately.
- Verify the app opens one main window and does not unexpectedly autoplay.
- Native build, signing, bookmark behavior and playback require local macOS validation.

### M3 feedback regression checks
- Launch the main window; default size is 640 × 850 points, with macOS allowed to constrain or restore window size.
- Import at least four tracks, play the last library row, enable shuffle; all other playable tracks should become upcoming without restarting the current song.
- Next and automatic advancement follow shuffled order, with no repeats within a cycle. Repeat all reshuffles at the boundary; repeat one repeats only on natural completion.
- With no current song, enable shuffle then press Play to start the shuffled queue. Turn shuffle off to restore library order. Relaunch to verify queue persistence.

## M4 WebKit experiment
The experiment uses a separate visible Spotify window, WKWebView with persistent application-scoped website data and outgoing networking only. Main-frame navigation is limited to HTTPS Spotify hosts; external user-clicked links may open in the system browser. Some federated login flows may not work. Spotify itself handles credentials and playback; the app does not inject scripts, inspect session tokens, modify ads, or access private APIs. Opening the window from the local player pauses local playback; there is not yet a global playback coordinator. Closing the window unloads its web page. See SPOTIFY_WEBPLAYER_EXPERIMENT.md for tests and limitations.
