import Foundation

struct Track: Identifiable {
    let id: UUID
    let url: URL
    let metadata: TrackMetadata
    let bookmark: Data
    let available: Bool

    init(id: UUID = UUID(), url: URL, metadata: TrackMetadata, bookmark: Data, available: Bool = true) {
        self.id = id
        self.url = url
        self.metadata = metadata
        self.bookmark = bookmark
        self.available = available
    }
}

struct SavedTrack: Codable {
    let id: UUID
    let path: String
    let bookmark: Data
    let title: String
    let artist: String
    let album: String
    let format: String

    init(_ track: Track) {
        id = track.id
        path = track.url.path
        bookmark = track.bookmark
        title = track.metadata.title
        artist = track.metadata.artist
        album = track.metadata.album
        format = track.metadata.format
    }

    var fallbackMetadata: TrackMetadata {
        var metadata = TrackMetadata()
        metadata.title = title
        metadata.artist = artist
        metadata.album = album
        metadata.format = format
        return metadata
    }
}
