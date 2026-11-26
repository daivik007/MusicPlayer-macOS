
import Foundation
import AVFoundation
import AppKit

struct TrackMetadata {
    var title: String = "Unknown Title"
    var artist: String = "Unknown Artist"
    var album: String = "Unknown Album"
    var artwork: NSImage?
    var format: String = ""
    var sampleRate: Double = 0
    var bitDepth: Int = 0
    var bitrate: Double = 0
    var channels: Int = 0
}

class MetadataManager {
    
    static func extract(from url: URL) async -> TrackMetadata {
        
        var result = TrackMetadata()
        
        result.title = url.deletingPathExtension()
            .lastPathComponent
        
        result.format = url.pathExtension.uppercased()
        
        let asset = AVURLAsset(url: url)
        
        // Extract embedded metadata
        if let metadata = try? await asset.load(.commonMetadata) {
            
            for item in metadata {
                switch item.commonKey {
                    
                case .commonKeyTitle:
                    result.title =
                        (try? await item.load(.stringValue))
                        ?? result.title
                    
                case .commonKeyArtist:
                    result.artist =
                        (try? await item.load(.stringValue))
                        ?? result.artist
                    
                case .commonKeyAlbumName:
                    result.album =
                        (try? await item.load(.stringValue))
                        ?? result.album
                    
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        result.artwork = NSImage(data: data)
                    }
                    
                default:
                    break
                }
            }
        }
        
        // Extract audio format information
        if let audioFile = try? AVAudioFile(forReading: url) {
            
            let format = audioFile.fileFormat
            let description = format.streamDescription.pointee
            
            result.sampleRate = format.sampleRate
            result.channels = Int(format.channelCount)
            result.bitDepth = Int(description.mBitsPerChannel)
        }
        
        // Estimate average file bitrate
        if let values = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ),
        let fileSize = values.fileSize,
        let duration = try? await asset.load(.duration),
        duration.seconds.isFinite,
        duration.seconds > 0 {
            
            result.bitrate =
                Double(fileSize) * 8 / duration.seconds / 1000
        }
        
        return result
    }
}
