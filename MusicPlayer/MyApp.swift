import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        Window("MusicPlayer", id: "main") {
            ContentView()
        }
        .defaultSize(width: 640, height: 850)
        Window("Spotify Web Player — Experiment", id: "spotify-web") {
            SpotifyWebPlayerView()
        }
        .defaultSize(width: 1050, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }
}
