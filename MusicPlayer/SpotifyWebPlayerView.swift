import SwiftUI
import WebKit
import AppKit
import Combine

@MainActor
final class SpotifyWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let home = URL(string: "https://open.spotify.com/")!

    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var host = "open.spotify.com"
    @Published private(set) var errorMessage = ""
    @Published private(set) var clearing = false

    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent WebKit storage is scoped to this app, not Safari.
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        openHome()
    }

    func openHome() {
        guard !clearing else { return }
        errorMessage = ""
        webView.load(URLRequest(url: Self.home))
    }

    func reload() {
        guard !clearing else { return }
        errorMessage = ""
        if webView.url == nil { openHome() } else { webView.reload() }
    }

    func back() { if !clearing { webView.goBack() } }
    func forward() { if !clearing { webView.goForward() } }

    func closePlayback() {
        // Unload the page when the experiment window is closed.
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func updateNavigation() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        host = webView.url?.host ?? "open.spotify.com"
    }

    private func isSpotify(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return host == "spotify.com" || host.hasSuffix(".spotify.com")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // Subframe navigation remains controlled by WebKit and site policy.
        if action.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        if clearing {
            decisionHandler(url.scheme == "about" ? .allow : .cancel)
        } else if url.absoluteString == "about:blank" || isSpotify(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            // Do not embed arbitrary sites or intercept third-party credentials.
            if action.navigationType == .linkActivated && url.scheme == "https" {
                NSWorkspace.shared.open(url)
            } else {
                errorMessage = "External sign-in or navigation was not embedded. Use Spotify's own login or open Spotify in your browser."
            }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, isSpotify(url) {
            webView.load(action.request)
        } else if let url = action.request.url, url.scheme == "https",
                  action.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
        } else {
            errorMessage = "This popup login is not supported in the experiment."
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        updateNavigation()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavigation()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        updateNavigation()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        errorMessage = "WebKit content process ended. Reload to retry."
    }

    private func failed(_ error: Error) {
        loading = false
        updateNavigation()
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        // Avoid logging URLs, query parameters, cookies or credentials.
        errorMessage = "Web page failed to load (\(nsError.domain), \(nsError.code)). Try Reload."
    }

    func clearSession() async {
        guard !clearing else { return }
        clearing = true
        errorMessage = ""
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        let store = webView.configuration.websiteDataStore
        await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             modifiedSince: .distantPast) {
                pending.resume()
            }
        }
        clearing = false
        openHome()
    }
}

struct SpotifyWebContainer: NSViewRepresentable {
    let session: SpotifyWebSession
    func makeNSView(context: Context) -> WKWebView { session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct SpotifyWebPlayerView: View {
    @StateObject private var session = SpotifyWebSession()
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { session.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!session.canGoBack || session.clearing)
                    .help("Back")
                Button { session.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!session.canGoForward || session.clearing)
                    .help("Forward")
                Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(session.clearing)
                    .help("Reload")
                Button { session.openHome() } label: { Image(systemName: "house") }
                    .disabled(session.clearing)
                    .help("Spotify home")
                Spacer()
                Image(systemName: "lock")
                Text(session.host).font(.caption).textSelection(.enabled)
                if session.loading || session.clearing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open in Browser") { NSWorkspace.shared.open(SpotifyWebSession.home) }
                Button("Clear Session…") { confirmClear = true }
                    .disabled(session.clearing)
            }
            .padding(12)
            Divider()
            if !session.errorMessage.isEmpty {
                Text(session.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SpotifyWebContainer(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text("WebKit experiment • Use Spotify’s own controls • Playback and free-account compatibility are unverified")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(minWidth: 760, minHeight: 560)
        .confirmationDialog("Clear Spotify browser session?", isPresented: $confirmClear) {
            Button("Clear Session", role: .destructive) {
                Task { await session.clearSession() }
            }
        } message: {
            Text("Removes this app’s WebKit cookies and website storage. You may need to sign in again. Local songs and Safari data are unaffected.")
        }
        .onAppear {
            if session.webView.url == nil || session.webView.url?.scheme == "about" {
                session.openHome()
            }
        }
        .onDisappear { session.closePlayback() }
    }
}
