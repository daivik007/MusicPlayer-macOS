import Foundation

struct Track: Identifiable {
    let id = UUID()
    let url: URL
    let metadata: TrackMetadata
}
