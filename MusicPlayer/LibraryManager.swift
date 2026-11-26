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
    private var index: Int? { queue.firstIndex { $0.id == currentID } }

    var upNext: [Track] {
        guard let index else { return [] }
        return Array(queue.dropFirst(index + 1))
    }

    var canGoNext: Bool {
        guard let index else { return false }
        return index + 1 < queue.count || repeatMode == .all
    }

    func importFiles(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        importError = ""
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !tracks.contains(where: {
                $0.url.standardizedFileURL.resolvingSymlinksInPath() == canonical
            }) else { continue }
            guard (try? AVAudioPlayer(contentsOf: url)) != nil else {
                failures.append(url.lastPathComponent)
                continue
            }
            let metadata = await MetadataManager.extract(from: url)
            tracks.append(Track(url: url, metadata: metadata))
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
        engine.loadAudio(url: track.url, cachedMetadata: track.metadata)
    }

    func next(using engine: AudioEngine) {
        guard let index else { return }
        if index + 1 < queue.count {
            start(queue[index + 1], using: engine)
        } else if repeatMode == .all, let first = queue.first {
            start(first, using: engine)
        }
    }

    func previous(using engine: AudioEngine) {
        guard let index else { return }
        if engine.currentTime > 3 || index == 0 {
            engine.seek(to: 0)
        } else {
            start(queue[index - 1], using: engine)
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
}
