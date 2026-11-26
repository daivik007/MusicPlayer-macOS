import Foundation
import WebKit

// Read-only observation in an isolated content world; no page API monkey-patching.
enum SpotifyMediaTrace {
    static let world = WKContentWorld.world(name: "MusicPlayerMediaDiagnostics")
    static let source = """
    (() => {
      if (!['open.spotify.com', 'sdk.scdn.co'].includes(location.hostname)) return;
      if (globalThis.__musicPlayerTrace) return;
      const events = [];
      const allowedErrors = new Set(['NotSupportedError','NotAllowedError','AbortError',
        'InvalidStateError','SecurityError','NetworkError','TypeError','ReferenceError',
        'SyntaxError','QuotaExceededError','EMEError','OperationError']);
      const label = e => allowedErrors.has(e?.name) ? e.name : 'other';
      const emit = (kind, details = {}) => {
        const event = { kind, ...details };
        events.push(event);
        if (events.length > 80) events.shift();
        window.webkit.messageHandlers.musicPlayerTrace.postMessage(event);
      };
      globalThis.__musicPlayerTrace = true;
      emit('document-start', { secure: isSecureContext,
        legacyFairPlay: typeof WebKitMediaKeys !== 'undefined',
        eme: typeof navigator.requestMediaKeySystemAccess === 'function' });
      for (const name of ['loadstart','loadedmetadata','canplay','play','playing','pause',
        'waiting','stalled','error','encrypted','webkitneedkey','ended','abort','emptied']) {
        document.addEventListener(name, e => {
          const m = e.target;
          if (!(m instanceof HTMLMediaElement)) return;
          emit(name, { kindOfMedia: m.tagName, ready: m.readyState, network: m.networkState,
            paused: m.paused, errorCode: m.error?.code ?? null, hasKeys: !!m.mediaKeys });
        }, true);
      }
      window.addEventListener('error', e => {
        if (e instanceof ErrorEvent) emit('javascript-error', { errorName: label(e.error) });
      }, true);
      window.addEventListener('unhandledrejection', e => {
        emit('unhandled-rejection', { errorName: label(e.reason) });
      });
      const seen = new WeakSet();
      const scan = () => {
        for (const m of document.querySelectorAll('audio,video')) {
          if (!seen.has(m)) {
            seen.add(m);
            emit('media-discovered', { kindOfMedia: m.tagName, ready: m.readyState,
              network: m.networkState, paused: m.paused });
          }
        }
      };
      document.addEventListener('DOMContentLoaded', () => {
        scan();
        new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
        emit('dom-ready');
      }, { once: true });
    })();
    """
}

@MainActor
final class SpotifyTraceReceiver: NSObject, WKScriptMessageHandler {
    weak var session: SpotifyWebSession?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let host = message.frameInfo.securityOrigin.host
        guard ["open.spotify.com", "sdk.scdn.co"].contains(host),
              message.frameInfo.securityOrigin.protocol == "https",
              let data = message.body as? [String: Any],
              let kind = data["kind"] as? String,
              ["document-start","dom-ready","media-discovered","loadstart","loadedmetadata",
               "canplay","play","playing","pause","waiting","stalled","error","encrypted",
               "webkitneedkey","ended","abort","emptied","javascript-error","unhandled-rejection"].contains(kind)
        else { return }
        var fields: [String] = []
        for key in ["secure","legacyFairPlay","eme","ready","network","paused","errorCode","hasKeys"] {
            if let value = data[key] as? NSNumber { fields.append("\(key)=\(value)") }
        }
        if let media = data["kindOfMedia"] as? String, ["AUDIO","VIDEO"].contains(media) {
            fields.append(media)
        }
        if let error = data["errorName"] as? String,
           ["NotSupportedError","NotAllowedError","AbortError","InvalidStateError","SecurityError",
            "NetworkError","TypeError","ReferenceError","SyntaxError","QuotaExceededError",
            "EMEError","OperationError","other"].contains(error) {
            fields.append(error)
        }
        session?.appendTrace("\(host) \(message.frameInfo.isMainFrame ? "main" : "frame"): \(kind) \(fields.joined(separator: " "))")
    }
}
