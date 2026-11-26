import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        Window("MusicPlayer", id: "main") {
            ContentView()
                .task {
                    #if DEBUG
                    await ECSDebugSmoke.runIfRequested() // no-op unless MUSICPLAYER_ECS_SMOKE_DIR is set
                    #endif
                }
        }
        .defaultSize(width: 640, height: 850)
    }
}
