
import Foundation
import AVFoundation
import Combine

class AudioEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    
    private var player: AVAudioPlayer?
    private var timer: Timer?
    
    @Published var isPlaying = false
    @Published var trackName = "No track selected"
    @Published var errorMessage = ""
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var metadata = TrackMetadata()

    private var metadataTask: Task<Void, Never>?

    
    func loadAudio(url: URL) {
        metadataTask?.cancel()
        metadata = TrackMetadata()
        metadata.title = url.deletingPathExtension().lastPathComponent
        do {
            player?.stop()
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
            
            metadataTask = Task { @MainActor [weak self] in
                let extracted = await MetadataManager.extract(from: url)
                
                guard !Task.isCancelled else { return }
                
                self?.metadata = extracted
                self?.trackName = extracted.title
            }

            play()
            
        } catch {
            player = nil
            errorMessage = error.localizedDescription
        }
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
        player?.currentTime = time
        currentTime = time
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
        timer?.invalidate()
        isPlaying = false
        currentTime = duration
    }
    
    deinit {
        timer?.invalidate()
    }
}
