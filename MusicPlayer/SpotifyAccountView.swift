import SwiftUI

struct SpotifyAccountView: View {
    @StateObject private var provider = SpotifyProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spotify").font(.largeTitle.bold())
            Text("Read-only developer integration. Spotify tracks open in Spotify; local FLAC playback is separate.")
                .foregroundStyle(.secondary)
            if provider.connected {
                Text(provider.profile?.display_name ?? provider.profile?.id ?? "Spotify account connected")
                    .font(.headline)
                HStack {
                    Button("Refresh Library") { Task { await provider.sync() } }
                    Button("Disconnect") { provider.logout() }
                }.disabled(provider.busy)
                List {
                    Section("Playlists (\(provider.playlists.count))") {
                        ForEach(provider.playlists) { playlist in
                            if let link = playlist.link { Link(playlist.name, destination: link) }
                        }
                    }
                    Section("Liked Songs (\(provider.liked.count))") {
                        ForEach(Array(provider.liked.enumerated()), id: \.offset) { _, track in
                            if let link = track.link {
                                Link(destination: link) {
                                    VStack(alignment: .leading) {
                                        Text(track.name)
                                        Text(track.artists?.map(\.name).joined(separator: ", ") ?? "")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                TextField("Spotify developer Client ID", text: $provider.clientID)
                    .textFieldStyle(.roundedBorder).disabled(provider.busy)
                Text("Register this redirect URI in your Spotify developer app:")
                Text(SpotifyOAuth.redirect).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Link("Spotify Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                HStack {
                    Button("Connect Spotify") { Task { await provider.login() } }
                        .disabled(provider.busy)
                    if provider.busy { Button("Cancel") { provider.cancelLogin() } }
                }
                Spacer()
            }
            if provider.busy { ProgressView().controlSize(.small) }
            if !provider.error.isEmpty {
                Text(provider.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
        .task { await provider.restore() }
    }
}
