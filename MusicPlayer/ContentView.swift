
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    
    @StateObject private var audioEngine = AudioEngine()
    
    var body: some View {
        VStack(spacing: 24) {
            
            Group {
                if let artwork = audioEngine.metadata.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.15))
                        
                        Image(systemName: "music.note")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 200, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12)
            
            
            VStack(spacing: 6) {
                
                Text(audioEngine.trackName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                if audioEngine.duration > 0 {
                    Text(audioEngine.metadata.artist)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    Text(audioEngine.metadata.album)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            
            if audioEngine.duration > 0 {
                HStack(spacing: 8) {
                    
                    Image(systemName: "waveform")
                    
                    Text(audioEngine.metadata.format)
                    
                    if audioEngine.metadata.bitDepth > 0 {
                        Text("·")
                        Text("\(audioEngine.metadata.bitDepth)-bit")
                    }
                    
                    if audioEngine.metadata.sampleRate > 0 {
                        Text("·")
                        Text(
                            String(
                                format: "%.1f kHz",
                                audioEngine.metadata.sampleRate / 1000
                            )
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            
            Button("Open Audio File") {
                openFile()
            }
            
            VStack(spacing: 8) {
                
                Slider(
                    value: Binding(
                        get: { audioEngine.currentTime },
                        set: { audioEngine.seek(to: $0) }
                    ),
                    in: 0...max(audioEngine.duration, 1)
                )
                .disabled(audioEngine.duration == 0)
                
                HStack {
                    Text(formatTime(audioEngine.currentTime))
                    
                    Spacer()
                    
                    Text(formatTime(audioEngine.duration))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            
            Button {
                audioEngine.togglePlayback()
            } label: {
                Image(systemName: audioEngine.isPlaying
                      ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            .disabled(audioEngine.duration == 0)
            
            if !audioEngine.errorMessage.isEmpty {
                Text(audioEngine.errorMessage)
                    .foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 600)
    }
    
    private func formatTime(_ time: Double) -> String {
        let seconds = Int(time)
        
        return String(
            format: "%d:%02d",
            seconds / 60,
            seconds % 60
        )
    }
    
    private func openFile() {
        let panel = NSOpenPanel()
        
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK,
           let url = panel.url {
            audioEngine.loadAudio(url: url)
        }
    }
}
