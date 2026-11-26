import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Compatibility baseline. Let the user choose a browser rather than assuming Chrome.
// Launch Services cannot reliably identify the rendering engine of arbitrary browsers.
@MainActor
struct ChromiumExperimentButton: View {
    let beforeOpen: () -> Void
    @AppStorage("chromiumExperiment.browserBundleID") private var browserID = ""
    @AppStorage("chromiumExperiment.browserPath") private var browserPath = ""
    @State private var errorMessage = ""
    private let spotify = URL(string: "https://open.spotify.com/")!

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if let browser = preferredBrowser() {
                    launch(browser)
                } else {
                    chooseBrowser(openAfterSelection: true)
                }
            } label: {
                Label("Spotify · Browser Test", systemImage: "globe")
            }
            .help("Open Spotify in your selected Chromium browser; not embedded playback.")
            Menu {
                Button("Choose Browser…") { chooseBrowser(openAfterSelection: false) }
                if let browser = NSWorkspace.shared.urlForApplication(toOpen: spotify) {
                    Button("Use Default Browser (\(browser.deletingPathExtension().lastPathComponent))") {
                        remember(browser)
                    }
                }
                if !browserPath.isEmpty {
                    Button("Forget Browser") {
                        browserID = ""
                        browserPath = ""
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(preferredBrowser()?.deletingPathExtension().lastPathComponent ?? "Select a Chromium browser")
        }
        .alert("Chromium experiment", isPresented: Binding(
            get: { !errorMessage.isEmpty },
            set: { if !$0 { errorMessage = "" } }
        )) {
            Button("OK", role: .cancel) { errorMessage = "" }
        } message: {
            Text(errorMessage)
        }
    }

    private func preferredBrowser() -> URL? {
        guard !browserPath.isEmpty else { return nil }
        let saved = URL(fileURLWithPath: browserPath)
        if FileManager.default.fileExists(atPath: saved.path),
           let bundle = Bundle(url: saved), bundle.bundleIdentifier == browserID {
            return saved
        }
        guard !browserID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID)
    }

    private func remember(_ browser: URL) {
        browserID = Bundle(url: browser)?.bundleIdentifier ?? ""
        browserPath = browser.path
    }

    private func chooseBrowser(openAfterSelection: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Chromium browser"
        panel.message = "Select Phi or another Chromium-based browser from Applications."
        panel.prompt = "Choose Browser"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let browser = panel.url else { return }
        guard Bundle(url: browser)?.bundleIdentifier != nil else {
            errorMessage = "Select a valid browser application."
            return
        }
        remember(browser)
        if openAfterSelection { launch(browser) }
    }

    private func launch(_ browser: URL) {
        beforeOpen()
        NSWorkspace.shared.open([spotify], withApplicationAt: browser,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                Task { @MainActor in
                    errorMessage = "The selected browser could not open Spotify. Choose it again or launch it directly."
                }
            }
        }
    }
}
