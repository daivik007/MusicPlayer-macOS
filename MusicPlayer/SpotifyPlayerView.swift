import Foundation
import SwiftUI

struct SpotifyPlayerView: View {
    let playback: PlaybackController

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            artwork
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 12)
            if let metadata = playback.snapshot?.mediaSession {
                Text(metadata.title ?? "Spotify")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if let artist = metadata.artist, !artist.isEmpty {
                    Text(artist).foregroundStyle(.secondary).lineLimit(1)
                }
                if let album = metadata.album, !album.isEmpty {
                    Text(album).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Text(status).font(.subheadline).foregroundStyle(.secondary)
            if let state = playback.snapshot, state.available {
                if let position = state.element?.currentTimeSec, let duration = state.element?.durationSec,
                   state.capabilities?.positionAvailable == true, state.capabilities?.durationAvailable == true,
                   duration > 0 {
                    ProgressView(value: min(position, duration), total: duration)
                        .accessibilityLabel("Playback progress")
                }
                if state.capabilities?.positionAvailable == true || state.capabilities?.durationAvailable == true {
                    HStack {
                        if let position = state.element?.currentTimeSec { Text(timeLabel(position)) }
                        Spacer()
                        if let duration = state.element?.durationSec { Text(timeLabel(duration)) }
                    }
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let volume = state.element?.volume {
                    Text("Page volume \(volume.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state.capabilities?.canSetMuted == true {
                    Button(playback.muted == true ? "Unmute Spotify Output" : "Mute Spotify Output") {
                        Task { await playback.toggleOutputMute() }
                    }
                    .disabled(!playback.canSetMuted)
                }
            }

            if playback.canConnect {
                Button("Connect to Spotify") { Task { await playback.connect() } }
            }
            if let error = playback.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let error = playback.actionError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if playback.connection == .ready {
                Text("Use the Spotify window for playback controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = playback.snapshot?.mediaSession?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                artworkPlaceholder
            }
        } else {
            artworkPlaceholder
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.gray.opacity(0.15)
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch playback.connection {
        case .stopped: return "Spotify disconnected"
        case .starting: return "Connecting to Spotify…"
        case .stopping: return "Closing Spotify…"
        case .failed(let message): return playback.errorMessage == nil ? message : "Spotify could not start"
        case .crashed(let code): return "Spotify runtime exited (\(code))"
        case .ready:
            switch playback.snapshot?.status {
            case "playing": return "Playing"
            case "paused": return "Paused"
            case "buffering": return "Buffering"
            case "idle": return "Idle"
            case "unknown": return "Playback status unavailable"
            default:
                if playback.snapshot?.reason == "page_not_spotify_player" {
                    return "Open the player or sign in from the Spotify window"
                }
                if playback.snapshot == nil && playback.errorMessage == nil { return "Reading Spotify playback…" }
                return "Spotify playback unavailable"
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        Duration.seconds(min(seconds, 315_576_000)).formatted(.time(pattern: .minuteSecond))
    }
}
