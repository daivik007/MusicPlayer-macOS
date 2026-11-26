import SwiftUI
import AppKit

// Compatibility baseline using an installed, supported browser.
// No embedded Chromium, profile access, debug port or credential bridge.
@MainActor
struct ChromiumExperimentButton: View {
    let beforeOpen: () -> Void
    @State private var errorMessage = ""

    var body: some View {
        Button {
            guard let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                errorMessage = "Google Chrome is not installed. Install the official macOS version, or run the standalone CEF test described in CHROMIUM_EXPERIMENT.md."
                return
            }
            beforeOpen()
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([URL(string: "https://open.spotify.com/")!],
                                    withApplicationAt: browser, configuration: configuration) { _, error in
                if error != nil {
                    Task { @MainActor in
                        errorMessage = "Chrome could not be opened. Try launching it directly."
                    }
                }
            }
        } label: {
            Label("Spotify · Chrome Test", systemImage: "globe")
        }
        .help("Open the official Spotify web player in installed Chrome; not embedded playback.")
        .alert("Chromium experiment", isPresented: Binding(
            get: { !errorMessage.isEmpty },
            set: { if !$0 { errorMessage = "" } }
        )) {
            Button("OK", role: .cancel) { errorMessage = "" }
        } message: {
            Text(errorMessage)
        }
    }
}
