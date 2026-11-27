import AppKit
import Foundation
import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(MusicPlayerDelegate.self) private var appDelegate

    var body: some Scene {
        Window("MusicPlayer", id: "main") {
            ContentView(playback: appDelegate.playback)
                .task {
                    #if DEBUG
                    await ECSDebugSmoke.runIfRequested()
                    #endif
                }
        }
        .defaultSize(width: 640, height: 850)
    }
}

@MainActor
final class MusicPlayerDelegate: NSObject, NSApplicationDelegate {
    let playback = PlaybackController(runtime: MusicPlayerDelegate.spotifyConfiguration().map { ECSRuntime(configuration: $0) })

    private static func spotifyConfiguration() -> ECSRuntimeConfiguration? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MUSICPLAYER_ECS_DIR"], path.hasPrefix("/") {
            return .development(appDirectory: URL(fileURLWithPath: path, isDirectory: true))
        }
        #endif
        return nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard playback.shouldShutDown else { return .terminateNow }
        Task {
            await playback.shutDownForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
