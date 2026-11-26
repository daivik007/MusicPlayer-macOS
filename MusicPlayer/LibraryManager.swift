import Foundation
import AVFoundation
import Combine

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

@MainActor
final class LibraryManager: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isImporting = false
    @Published private(set) var importError = ""
    @Published private(set) var currentID: UUID?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isRestoring = false
    @Published private(set) var storageError = ""
    private var store: LibraryStore?
    private var didRestore = false
    private var lastSavedPosition: Double?
    private var index: Int? { queue.firstIndex { $0.id == currentID } }

    var upNext: [Track] {
        guard let index else { return [] }
        return Array(queue.dropFirst(index + 1))
    }

    var canGoNext: Bool {
        guard let index else { return false }
        return queue.dropFirst(index + 1).contains { $0.available }
            || (repeatMode == .all && queue.contains { $0.available })
    }

    func importFiles(_ urls: [URL]) async {
        guard !isImporting, !isRestoring else { return }
        isImporting = true
        importError = ""
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !tracks.contains(where: {
                $0.url.standardizedFileURL.resolvingSymlinksInPath() == canonical
            }) else { continue }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? makeBookmark(url), (try? AVAudioPlayer(contentsOf: url)) != nil else {
                failures.append(url.lastPathComponent)
                continue
            }
            let metadata = await MetadataManager.extract(from: url)
            tracks.append(Track(url: url, metadata: metadata, bookmark: bookmark))
        }
        if !failures.isEmpty {
            importError = "Could not import: " + failures.joined(separator: ", ")
        }
        let added = tracks.filter { track in !queue.contains { $0.id == track.id } }
        queue.append(contentsOf: shuffle ? added.shuffled() : added)
    }

    func select(_ track: Track, using engine: AudioEngine) {
        if shuffle {
            queue = [track] + tracks.filter { $0.id != track.id }.shuffled()
        } else {
            queue = tracks
        }
        start(track, using: engine)
    }

    private func start(_ track: Track, using engine: AudioEngine) {
        currentID = track.id
        if track.available {
            engine.loadAudio(url: track.url, cachedMetadata: track.metadata)
        } else {
            engine.clear()
            engine.errorMessage = "File unavailable. Locate it from the library row."
        }
        save(using: engine)
    }

    func next(using engine: AudioEngine) {
        guard let index else { return }
        if let next = queue.dropFirst(index + 1).first(where: { $0.available }) {
            start(next, using: engine)
        } else if repeatMode == .all, let first = queue.first(where: { $0.available }) {
            start(first, using: engine)
        }
    }

    func previous(using engine: AudioEngine) {
        guard let index else { return }
        if engine.currentTime > 3 || index == 0 {
            engine.seek(to: 0)
        } else if let previous = queue.prefix(index).last(where: { $0.available }) {
            start(previous, using: engine)
        } else {
            engine.seek(to: 0)
        }
    }

    func finished(using engine: AudioEngine) {
        if repeatMode == .one {
            engine.seek(to: 0)
            engine.play()
        } else {
            next(using: engine)
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        if shuffle, let index {
            let prefix = Array(queue.prefix(index + 1))
            queue = prefix + Array(queue.dropFirst(index + 1)).shuffled()
        } else if shuffle {
            queue = tracks.shuffled()
        } else {
            queue = tracks
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func makeBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func restore(using engine: AudioEngine) async {
        guard !didRestore else { return }
        didRestore = true
        isRestoring = true
        defer { isRestoring = false }
        do {
            let database = try LibraryStore()
            let state = try database.load()
            store = database
            shuffle = state.shuffle
            repeatMode = RepeatMode(rawValue: state.repeatMode) ?? .off
            for saved in state.tracks {
                var stale = false
                do {
                    let url = try URL(resolvingBookmarkData: saved.bookmark,
                        options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard (try? AVAudioPlayer(contentsOf: url)) != nil else {
                        throw StorageError(detail: "Audio file unavailable.")
                    }
                    let bookmark = stale ? (try makeBookmark(url)) : saved.bookmark
                    let metadata = await MetadataManager.extract(from: url)
                    tracks.append(Track(id: saved.id, url: url, metadata: metadata, bookmark: bookmark))
                } catch {
                    tracks.append(Track(id: saved.id, url: URL(fileURLWithPath: saved.path),
                        metadata: saved.fallbackMetadata, bookmark: saved.bookmark, available: false))
                }
            }
            var seen = Set<UUID>()
            queue = state.queueIDs.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                return tracks.first { $0.id == id }
            }
            queue += tracks.filter { track in !queue.contains { $0.id == track.id } }
            if let track = tracks.first(where: { $0.id == state.currentID }) {
                currentID = track.id
                if track.available && engine.loadAudio(url: track.url, cachedMetadata: track.metadata, autoplay: false) {
                    engine.seek(to: state.position.isFinite ? state.position : 0)
                } else if !track.available {
                    engine.errorMessage = "Last played file is unavailable. Locate it from the library row."
                }
            }
            lastSavedPosition = nil
        } catch {
            // Never overwrite a database that could not be read.
            store = nil
            storageError = "Library could not be restored: " + error.localizedDescription
        }
    }

    func save(using engine: AudioEngine, periodic: Bool = false) {
        guard didRestore, !isRestoring, let store else { return }
        let position = engine.currentTime.isFinite ? max(0, engine.currentTime) : 0
        if periodic, let lastSavedPosition, abs(lastSavedPosition - position) < 1 { return }
        var state = SavedLibrary()
        state.tracks = tracks.map(SavedTrack.init)
        state.queueIDs = queue.map { $0.id }
        state.currentID = currentID
        state.position = position
        state.shuffle = shuffle
        state.repeatMode = repeatMode.rawValue
        do {
            try store.save(state)
            lastSavedPosition = position
            storageError = ""
        } catch {
            storageError = "Library could not be saved: " + error.localizedDescription
        }
    }

    func remove(_ track: Track, using engine: AudioEngine) {
        guard !isRestoring, !isImporting else { return }
        tracks.removeAll { $0.id == track.id }
        queue.removeAll { $0.id == track.id }
        if currentID == track.id {
            currentID = nil
            engine.clear()
        }
        save(using: engine)
    }

    func relocate(_ track: Track, to url: URL, using engine: AudioEngine) async {
        guard !isRestoring, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        importError = ""
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !tracks.contains(where: {
                $0.id != track.id && $0.url.standardizedFileURL.resolvingSymlinksInPath() == canonical
            }) else { throw StorageError(detail: "This file is already in the library.") }
            let bookmark = try makeBookmark(url)
            _ = try AVAudioPlayer(contentsOf: url)
            let metadata = await MetadataManager.extract(from: url)
            let replacement = Track(id: track.id, url: url, metadata: metadata, bookmark: bookmark)
            if let i = tracks.firstIndex(where: { $0.id == track.id }) { tracks[i] = replacement }
            if let i = queue.firstIndex(where: { $0.id == track.id }) { queue[i] = replacement }
            if currentID == track.id {
                engine.loadAudio(url: url, cachedMetadata: metadata, autoplay: false)
            }
            save(using: engine)
        } catch {
            importError = "Could not locate file: " + error.localizedDescription
        }
    }
}
