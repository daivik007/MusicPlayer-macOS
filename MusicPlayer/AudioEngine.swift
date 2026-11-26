
import Foundation
import AVFoundation
import Combine

class AudioEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var scopedURL: URL?
    var onFinished: (() -> Void)?
    
    @Published var isPlaying = false
    @Published var trackName = "No track selected"
    @Published var errorMessage = ""
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var metadata = TrackMetadata()

    private var metadataTask: Task<Void, Never>?

    
    @discardableResult
    func loadAudio(url: URL, cachedMetadata: TrackMetadata? = nil, autoplay: Bool = true) -> Bool {
        metadataTask?.cancel()
        metadata = cachedMetadata ?? TrackMetadata()
        metadata.title = url.deletingPathExtension().lastPathComponent
        do {
            player?.stop()
            player = nil
            releaseFileAccess()
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
            timer?.invalidate()
            
            isPlaying = false
            currentTime = 0
            duration = 0
            
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            
            trackName = url.deletingPathExtension()
                .lastPathComponent
            
            duration = player?.duration ?? 0
            errorMessage = ""
            
            if let cachedMetadata {
                metadata = cachedMetadata
                trackName = cachedMetadata.title
            } else {
            metadataTask = Task { @MainActor [weak self] in
                let extracted = await MetadataManager.extract(from: url)
                
                guard !Task.isCancelled else { return }
                
                self?.metadata = extracted
                self?.trackName = extracted.title
            }
            }

            if autoplay {
                play()
                if !isPlaying { errorMessage = "Could not start playback." }
                return isPlaying
            }
            return true
            
        } catch {
            player = nil
            releaseFileAccess()
            trackName = metadata.title
            errorMessage = error.localizedDescription
            return false
        }
    }
    
    private func releaseFileAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    func clear() {
        metadataTask?.cancel()
        timer?.invalidate()
        player?.stop()
        player = nil
        releaseFileAccess()
        isPlaying = false
        currentTime = 0
        duration = 0
        metadata = TrackMetadata()
        trackName = "No track selected"
        errorMessage = ""
    }

    func play() {
        if currentTime >= duration {
            player?.currentTime = 0
            currentTime = 0
        }
        
        isPlaying = player?.play() ?? false
        
        if isPlaying {
            startTimer()
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }
    
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to time: Double) {
        let bounded = min(max(time, 0), duration)
        player?.currentTime = bounded
        currentTime = bounded
    }
    
    private func startTimer() {
        timer?.invalidate()
        
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            guard let self = self else { return }
            self.currentTime = self.player?.currentTime ?? 0
        }
    }
    
    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        guard player === self.player else { return }
        timer?.invalidate()
        isPlaying = false
        currentTime = duration
        if flag { onFinished?() } else { errorMessage = "Playback ended unexpectedly." }
    }
    
    deinit {
        timer?.invalidate()
        scopedURL?.stopAccessingSecurityScopedResource()
    }
}
