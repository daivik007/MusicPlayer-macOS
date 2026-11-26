import Foundation
import CryptoKit
import Security
import Network
import AppKit

enum SpotifyFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

struct SpotifyToken: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let clientID: String
}

struct SpotifyTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
}

enum SpotifyKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "MusicPlayer.Spotify",
         kSecAttrAccount as String: "oauth"]
    }
    static func load() throws -> SpotifyToken? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SpotifyFailure.message("Keychain read failed (\(status)).")
        }
        return try JSONDecoder().decode(SpotifyToken.self, from: data)
    }
    static func save(_ token: SpotifyToken) throws {
        let data = try JSONEncoder().encode(token)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
                throw SpotifyFailure.message("Could not store Spotify session in Keychain.")
            }
        } else if status != errSecSuccess {
            throw SpotifyFailure.message("Keychain update failed (\(status)).")
        }
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SpotifyFailure.message("Keychain removal failed (\(status)).")
        }
    }
}

@MainActor
final class SpotifyOAuth {
    static let redirect = "http://127.0.0.1:43821/callback"
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var expectedState = ""

    private func randomString() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw SpotifyFailure.message("Could not generate secure random data.") }
        return Self.base64URL(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func authorize(clientID: String) async throws -> SpotifyToken {
        let verifier = try randomString()
        expectedState = try randomString()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
        parts.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: expectedState),
            .init(name: "scope", value: "playlist-read-private playlist-read-collaborative user-library-read")
        ]
        guard let url = parts.url else { throw SpotifyFailure.message("Invalid authorization URL.") }
        let code = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<String, Error>) in
                continuation = pending
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
                    let server = try NWListener(using: parameters)
                    listener = server
                    server.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self, self.continuation != nil else { return }
                            switch state {
                            case .ready:
                                if !NSWorkspace.shared.open(url) {
                                    self.finish(.failure(SpotifyFailure.message("Could not open browser.")))
                                }
                            case .failed(let error):
                                self.finish(.failure(SpotifyFailure.message("Callback listener failed: \(error.localizedDescription)")))
                            default: break
                            }
                        }
                    }
                    server.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in self?.accept(connection) }
                    }
                    server.start(queue: .main)
                    timeout = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(180))
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(SpotifyFailure.message("Spotify sign-in timed out.")))
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        return try await Self.exchange([
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": Self.redirect, "client_id": clientID, "code_verifier": verifier
        ], clientID: clientID, previousRefresh: nil)
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<String, Error>) {
        let pending = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        pending?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                var request = accumulated
                if let data { request.append(data) }
                guard request.count <= 16384, error == nil else { connection.cancel(); return }
                if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                    self.handle(text, connection: connection)
                } else if complete {
                    connection.cancel()
                } else {
                    self.receive(connection, accumulated: request)
                }
            }
        }
    }

    private func handle(_ request: String, connection: NWConnection) {
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let fields = line.split(separator: " ")
        guard fields.count == 3, fields[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1:43821" + String(fields[1])),
              components.path == "/callback",
              let items = components.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState else {
            respond(connection, ok: false)
            return
        }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
           items.filter({ $0.name == "code" }).count == 1,
           !items.contains(where: { $0.name == "error" }) {
            respond(connection, ok: true)
            finish(.success(code))
        } else {
            respond(connection, ok: false)
            finish(.failure(SpotifyFailure.message("Spotify authorization was denied or cancelled.")))
        }
    }

    private func respond(_ connection: NWConnection, ok: Bool) {
        let body = ok ? "Authorization received. Return to MusicPlayer." : "Authorization not accepted. Return to MusicPlayer."
        let response = "HTTP/1.1 \(ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    static func refresh(_ token: SpotifyToken) async throws -> SpotifyToken {
        try await exchange(["grant_type": "refresh_token", "refresh_token": token.refreshToken,
                            "client_id": token.clientID], clientID: token.clientID,
                           previousRefresh: token.refreshToken)
    }

    private static func exchange(_ values: [String: String], clientID: String, previousRefresh: String?) async throws -> SpotifyToken {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(values.sorted(by: { $0.key < $1.key }).map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyFailure.message("Spotify token request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)). Check your Client ID and account access.")
        }
        let result = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        guard let refresh = result.refresh_token ?? previousRefresh else {
            throw SpotifyFailure.message("Spotify did not return a refresh token.")
        }
        return SpotifyToken(accessToken: result.access_token, refreshToken: refresh,
                            expiresAt: Date().addingTimeInterval(Double(result.expires_in)), clientID: clientID)
    }
}
