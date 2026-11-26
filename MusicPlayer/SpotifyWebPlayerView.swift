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

    @Published private(set) var report = "No report yet. Attempt playback, then run diagnostics."
    @Published private(set) var diagnosing = false
    private let traceReceiver = SpotifyTraceReceiver()
    private var trace: [String] = []
    let webView: WKWebView

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent WebKit storage is scoped to this app, not Safari.
        config.websiteDataStore = .default()
        // Request desktop layout through WebKit's public preference, not a forged user agent.
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        // Spotify may start media asynchronously after the user clicks Play.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.addUserScript(WKUserScript(source: SpotifyMediaTrace.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: SpotifyMediaTrace.world))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        traceReceiver.session = self
        config.userContentController.add(traceReceiver, contentWorld: SpotifyMediaTrace.world, name: "musicPlayerTrace")
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        webView.navigationDelegate = self
        webView.uiDelegate = self
        openHome()
    }

    func appendTrace(_ event: String) {
        trace.append(event)
        if trace.count > 120 { trace.removeFirst(trace.count - 120) }
    }

    func resetTrace() {
        trace.removeAll()
        appendTrace("Trace reset; attempt playback now.")
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
        appendTrace("Navigation started")
        loading = true
        updateNavigation()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavigation()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        appendTrace("Navigation finished")
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
        appendTrace("Navigation failed (\(nsError.domain), \(nsError.code))")
        errorMessage = "Web page failed to load (\(nsError.domain), \(nsError.code)). Try Reload."
    }

    func runDiagnostics() async {
        guard !diagnosing, !clearing, webView.url?.host == "open.spotify.com" else {
            report = "Open open.spotify.com and finish signing in before running diagnostics."
            return
        }
        diagnosing = true
        defer { diagnosing = false }
        let script = """
        const a = document.createElement('audio');
        const result = {
          secureContext: window.isSecureContext,
          visibility: document.visibilityState,
          userAgent: navigator.userAgent,
          platform: navigator.platform,
          maxTouchPoints: navigator.maxTouchPoints,
          viewport: { width: innerWidth, height: innerHeight, devicePixelRatio },
          pointer: { fine: matchMedia('(pointer: fine)').matches,
            hover: matchMedia('(hover: hover)').matches },
          playerBundleHints: (() => {
            const urls = [...Array.from(document.scripts, s => s.src),
              ...performance.getEntriesByType('resource').filter(r => r.initiatorType === 'script').map(r => r.name)];
            let mobile = false, desktop = false, generic = false;
            for (const raw of urls) {
              try {
                const u = new URL(raw);
                if (u.protocol !== 'https:' || !['open.spotify.com','open.spotifycdn.com','open.scdn.co'].includes(u.hostname)) continue;
                const p = u.pathname.toLowerCase();
                if (p.includes('mobile-web-player')) mobile = true;
                else if (p.includes('desktop-web-player')) desktop = true;
                else if (p.includes('web-player')) generic = true;
              } catch (_) {}
            }
            return { mobile, desktop, generic };
          })(),
          encryptedMediaAPI: typeof navigator.requestMediaKeySystemAccess === 'function',
          legacyFairPlay: typeof WebKitMediaKeys !== 'undefined' ?
            (() => { try { return WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'audio/mp4'); }
              catch (_) { return false; } })() : false,
          frameCount: document.querySelectorAll('iframe').length,
          mediaSource: typeof MediaSource !== 'undefined',
          managedMediaSource: typeof ManagedMediaSource !== 'undefined',
          webAudio: typeof AudioContext !== 'undefined' || typeof webkitAudioContext !== 'undefined',
          aac: a.canPlayType('audio/mp4; codecs="mp4a.40.2"'),
          opus: a.canPlayType('audio/webm; codecs="opus"'),
          mp3: a.canPlayType('audio/mpeg'),
          mediaElements: Array.from(document.querySelectorAll('audio, video')).slice(0, 12).map(m => ({
            kind: m.tagName, paused: m.paused, muted: m.muted, volume: m.volume,
            readyState: m.readyState, networkState: m.networkState,
            currentTime: Number.isFinite(m.currentTime) ? Math.round(m.currentTime * 10) / 10 : null,
            errorCode: m.error ? m.error.code : null,
            hasMediaKeys: !!m.mediaKeys
          }))
        };
        // Query only standard capability APIs. No license requests, media extraction,
        // cookies, account details, URLs, or modification of the page.
        if (result.encryptedMediaAPI) {
          const cfg = [{ initDataTypes: ['cenc'], audioCapabilities: [
            { contentType: 'audio/mp4; codecs="mp4a.40.2"' }
          ], distinctiveIdentifier: 'not-allowed', persistentState: 'not-allowed',
          sessionTypes: ['temporary'] }];
          const probe = async (key, config) => {
            try {
              return await Promise.race([
                navigator.requestMediaKeySystemAccess(key, config).then(() => 'accepted', e => e.name || 'rejected'),
                new Promise(resolve => setTimeout(() => resolve('timed out'), 4000))
              ]);
            } catch (e) { return e.name || 'failed'; }
          };
          result.fairPlayLegacyEME = await probe('com.apple.fps.1_0', [{
            initDataTypes: ['sinf'],
            audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }],
            distinctiveIdentifier: 'not-allowed', persistentState: 'not-allowed',
            sessionTypes: ['temporary']
          }]);
          result.widevine = await probe('com.widevine.alpha', cfg);
          result.fairPlay = await probe('com.apple.fps', [{
            initDataTypes: ['sinf'],
            audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }],
            distinctiveIdentifier: 'not-allowed', persistentState: 'not-allowed',
            sessionTypes: ['temporary']
          }]);
        }
        return JSON.stringify(result, null, 2);
        """
        do {
            let result = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            let payload = result as? String ?? "Unexpected JavaScript response."
            report = "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nMedia gesture requirement: none (experimental)\nPreferred content mode: desktop\nCustom user agent: none\n\n" + payload + "\n\nObserved events (latest 120):\n" + (trace.isEmpty ? "None" : trace.joined(separator: "\n"))
        } catch {
            let ns = error as NSError
            report = "Diagnostic script failed (\(ns.domain), \(ns.code)). Reload and retry."
        }
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
    @State private var showDiagnostics = false

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
                Button("Reset Trace") { session.resetTrace() }.help("Clear event history before trying Play")
                Button("Diagnostics") { showDiagnostics = true; Task { await session.runDiagnostics() } }
                    .disabled(session.clearing || session.diagnosing)
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
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Playback diagnostics").font(.title2.bold())
                Text("Capability probes are not proof of Spotify DRM compatibility. No account data or media URLs are collected.")
                    .font(.caption).foregroundStyle(.secondary)
                if session.diagnosing { ProgressView("Checking media capabilities…") }
                ScrollView {
                    Text(session.report).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Run Again") { Task { await session.runDiagnostics() } }
                        .disabled(session.diagnosing)
                    Button("Copy Report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.report, forType: .string)
                    }.disabled(session.diagnosing)
                    Spacer()
                    Button("Done") { showDiagnostics = false }
                }
            }.padding(20).frame(width: 660, height: 520)
        }
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
