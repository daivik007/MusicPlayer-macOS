import Foundation
import Combine

struct SpotifyProfile: Decodable {
    let id: String
    let display_name: String?
}

struct SpotifyPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let external_urls: [String: String]?
    var link: URL? { URL(string: "https://open.spotify.com/playlist/" + id) }
}

struct SpotifyTrack: Decodable {
    struct Artist: Decodable { let name: String }
    let id: String?
    let name: String
    let artists: [Artist]?
    let external_urls: [String: String]?
    var link: URL? { id.flatMap { URL(string: "https://open.spotify.com/track/" + $0) } }
}

struct SpotifySavedItem: Decodable {
    let track: SpotifyTrack?
}

struct SpotifyPage<Item: Decodable>: Decodable {
    let items: [Item?]
    let next: String?
}

@MainActor
final class SpotifyProvider: ObservableObject {
    @Published var clientID = UserDefaults.standard.string(forKey: "spotify.clientID") ?? ""
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var profile: SpotifyProfile?
    @Published private(set) var playlists: [SpotifyPlaylist] = []
    @Published private(set) var liked: [SpotifyTrack] = []
    @Published private(set) var error = ""
    private var token: SpotifyToken?
    private let oauth = SpotifyOAuth()
    private var restored = false

    func restore() async {
        guard !restored, !busy else { return }
        restored = true
        do {
            if let saved = try SpotifyKeychain.load() {
                token = saved
                clientID = saved.clientID
                connected = true
                await sync()
            }
        } catch { self.error = error.localizedDescription }
    }

    func login() async {
        guard !busy, !connected else { return }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            error = "Enter a valid Spotify developer Client ID."
            return
        }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let session = try await oauth.authorize(clientID: id)
            try SpotifyKeychain.save(session)
            token = session
            clientID = id
            UserDefaults.standard.set(id, forKey: "spotify.clientID")
            connected = true
            await loadLibrary()
        } catch is CancellationError {
            error = "Sign-in cancelled."
        } catch { self.error = error.localizedDescription }
    }

    func cancelLogin() { oauth.cancel() }

    func logout() {
        guard !busy else { return }
        do {
            try SpotifyKeychain.clear()
            token = nil
            connected = false
            profile = nil
            playlists = []
            liked = []
            error = ""
        } catch { self.error = error.localizedDescription }
    }

    func sync() async {
        guard connected, !busy else { return }
        busy = true
        defer { busy = false }
        await loadLibrary()
    }

    private func loadLibrary() async {
        var failures: [String] = []
        do { profile = try await get("https://api.spotify.com/v1/me") }
        catch { failures.append("Profile: " + error.localizedDescription) }
        do { playlists = try await pages("https://api.spotify.com/v1/me/playlists?limit=50") }
        catch { failures.append("Playlists: " + error.localizedDescription) }
        do {
            let items: [SpotifySavedItem] = try await pages("https://api.spotify.com/v1/me/tracks?limit=50")
            liked = items.compactMap(\.track)
        } catch { failures.append("Liked songs: " + error.localizedDescription) }
        error = failures.joined(separator: "\n")
    }

    private func validToken(force: Bool = false) async throws -> String {
        guard let token else { throw SpotifyFailure.message("Sign in first.") }
        if !force && token.expiresAt.timeIntervalSinceNow > 60 { return token.accessToken }
        let refreshed = try await SpotifyOAuth.refresh(token)
        try SpotifyKeychain.save(refreshed)
        self.token = refreshed
        return refreshed.accessToken
    }

    private func get<T: Decodable>(_ address: String) async throws -> T {
        guard let url = URL(string: address), url.scheme == "https", url.host == "api.spotify.com",
              url.port == nil, url.user == nil, url.password == nil else {
            throw SpotifyFailure.message("Invalid Spotify API URL.")
        }
        for attempt in 0...1 {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer " + (try await validToken(force: attempt == 1)), forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SpotifyFailure.message("Invalid response.") }
            if http.statusCode == 401 && attempt == 0 { continue }
            switch http.statusCode {
            case 200: return try JSONDecoder().decode(T.self, from: data)
            case 403: throw SpotifyFailure.message("Access denied. Check Premium, test-user allowlist and API permissions.")
            case 429: throw SpotifyFailure.message("Rate limited. Retry after \(http.value(forHTTPHeaderField: "Retry-After") ?? "a few") seconds.")
            default: throw SpotifyFailure.message("Spotify HTTP \(http.statusCode).")
            }
        }
        throw SpotifyFailure.message("Spotify session expired. Disconnect and sign in again.")
    }

    private func pages<T: Decodable>(_ first: String) async throws -> [T] {
        var address: String? = first
        var seen = Set<String>()
        var result: [T] = []
        while let url = address {
            guard seen.insert(url).inserted else { throw SpotifyFailure.message("Repeated pagination URL.") }
            let page: SpotifyPage<T> = try await get(url)
            result += page.items.compactMap { $0 }
            address = page.next
        }
        return result
    }
}
