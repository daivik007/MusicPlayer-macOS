
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    let playback: PlaybackController
    
    @StateObject private var audioEngine = AudioEngine()
    @StateObject private var library = LibraryManager()
    private let autosave = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(playback.source == .local ? "Local Music" : "Spotify",
                      systemImage: playback.source == .local ? "music.note" : "waveform")
                    .font(.headline)
                Spacer()
                if playback.source == .local {
                    Button("Spotify") {
                        Task {
                            await playback.selectSpotify {
                                audioEngine.pause()
                                library.save(using: audioEngine)
                            }
                        }
                    }
                    .disabled(!playback.spotifyConfigured)
                    .help(playback.spotifyConfigured ? "Open the Spotify player" : "Spotify requires a configured Debug launch")
                } else {
                    Button("Return to Local Music") { Task { await playback.selectLocal() } }
                        .disabled(playback.switchingToLocal)
                        .help("Closes the managed Spotify window and returns to the local queue")
                }
            }

            if playback.source == .local {
                localPlayer
            } else {
                SpotifyPlayerView(playback: playback)
            }
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 640, minHeight: 700, idealHeight: 850)
        .onAppear {
            audioEngine.onFinished = { [weak playback = playback, weak library = library, weak audioEngine = audioEngine] in
                guard playback?.source == .local, let library, let audioEngine else { return }
                library.finished(using: audioEngine)
                library.save(using: audioEngine)
            }
        }
        .task { await library.restore(using: audioEngine) }
        .onReceive(autosave) { _ in library.save(using: audioEngine, periodic: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            library.save(using: audioEngine)
        }
        .onDisappear { library.save(using: audioEngine) }
    }

    private var localPlayer: some View {
        VStack(spacing: 16) {
            
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

            
            HStack {
                Button("Import Music") { openFile() }
                    .disabled(library.isImporting || library.isRestoring)
                Spacer()
                Text("\(library.tracks.count) songs")
                    .foregroundStyle(.secondary)
                if library.isImporting || library.isRestoring { ProgressView().controlSize(.small) }
            }
            if !library.importError.isEmpty {
                Text(library.importError).font(.caption).foregroundStyle(.red)
            }
            if !library.storageError.isEmpty {
                Text(library.storageError).font(.caption).foregroundStyle(.red)
            }
            List(library.tracks) { track in
                Button {
                    library.select(track, using: audioEngine)
                } label: {
                    HStack {
                        if let art = track.metadata.artwork {
                            Image(nsImage: art).resizable().scaledToFill()
                                .frame(width: 36, height: 36).clipped()
                        } else {
                            Image(systemName: "music.note").frame(width: 36, height: 36)
                        }
                        VStack(alignment: .leading) {
                            Text(track.metadata.title).lineLimit(1)
                            Text(track.metadata.artist).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if library.currentID == track.id {
                            Image(systemName: audioEngine.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        if !track.available {
                            Text("Unavailable").font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(track.metadata.format).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.isRestoring)
                .contextMenu {
                    Button("Locate File…") { locateFile(track) }
                        .disabled(library.isImporting || library.isRestoring)
                    Button("Remove from Library", role: .destructive) {
                        library.remove(track, using: audioEngine)
                    }
                    .disabled(library.isImporting || library.isRestoring)
                }
            }
            .frame(minHeight: 140, idealHeight: 220)
            if !library.shuffle && !library.upNext.isEmpty {
                HStack {
                    Text("Up Next").font(.caption).bold()
                    Spacer()
                    Text(library.upNext.map { $0.metadata.title }.joined(separator: " · "))
                        .font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            
            VStack(spacing: 8) {
                
                Slider(
                    value: Binding(
                        get: { audioEngine.currentTime },
                        set: { audioEngine.seek(to: $0) }
                    ),
                    in: 0...max(audioEngine.duration, 1),
                    onEditingChanged: { editing in
                        if !editing { library.save(using: audioEngine) }
                    }
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
            
            HStack(spacing: 24) {
                Button { library.toggleShuffle(); library.save(using: audioEngine) } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(library.shuffle ? Color.accentColor : Color.secondary)
                }
                .help(library.shuffle ? "Shuffle on" : "Shuffle off")
                .disabled(library.isRestoring)
                Button { library.previous(using: audioEngine); library.save(using: audioEngine) } label: {
                    Image(systemName: "backward.fill")
                }
                .disabled(library.currentID == nil)
                .help("Previous")
                Button { library.playOrPause(using: audioEngine); library.save(using: audioEngine) } label: {
                    Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                }
                .disabled(library.isRestoring || (audioEngine.duration == 0 && (library.currentID != nil || !library.tracks.contains { $0.available })))
                .help("Play or pause")
                Button { library.next(using: audioEngine) } label: {
                    Image(systemName: "forward.fill")
                }
                .disabled(!library.canGoNext)
                .help("Next")
                Button { library.cycleRepeat(); library.save(using: audioEngine) } label: {
                    Image(systemName: library.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(library.repeatMode == .off ? Color.secondary : Color.accentColor)
                }
                .help("Repeat: \(library.repeatMode.rawValue)")
            }
            .buttonStyle(.plain)
            
            if !audioEngine.errorMessage.isEmpty {
                Text(audioEngine.errorMessage)
                    .foregroundStyle(.red)
            }
        }
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task {
                await library.importFiles(urls)
                library.save(using: audioEngine)
            }
        }
    }

    private func locateFile(_ track: Track) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await library.relocate(track, to: url, using: audioEngine) }
        }
    }
}
