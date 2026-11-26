import Foundation

// M4B: wire types and configuration for the stdio bridge to the independent ECS (Electron) runtime.
// Protocol: newline-delimited JSON, see experiments/spotify-ecs/bridge.cjs.
// The module defaults to MainActor isolation, so everything shared with the ECSRuntime actor is explicitly nonisolated.

nonisolated enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
}

extension JSONValue: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let d = try? container.decode(Double.self) { self = .number(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: Wire messages

nonisolated struct ECSRequestEnvelope: Encodable, Sendable {
    let v: Int
    let id: String
    let cmd: String
    let args: [String: JSONValue]
}

nonisolated struct ECSErrorPayload: Decodable, Sendable {
    let code: String
    let message: String
}

nonisolated struct ECSIncomingMessage: Decodable, Sendable {
    let v: Int?
    let id: String?
    let ok: Bool?
    let result: JSONValue?
    let error: ECSErrorPayload?
    let event: String?
    let data: JSONValue?
}

// MARK: Typed results for the initial command set

nonisolated struct ECSAuthStatus: Decodable, Sendable {
    /// "signed-in", "signed-out" or "unknown".
    let state: String
    /// Heuristic: presence of Spotify's own login cookie. The runtime never returns the cookie value, and the
    /// session is not verified against Spotify (verified is always false).
    let basis: String?
    let verified: Bool?
    let loginPage: Bool?
    let reason: String?
}

nonisolated struct ECSPlaybackState: Decodable, Sendable {
    nonisolated struct MediaSession: Decodable, Sendable {
        let playbackState: String
        let title: String?
        let artist: String?
        let album: String?
    }
    nonisolated struct MediaElement: Decodable, Sendable {
        let paused: Bool
        let ended: Bool
        let currentTimeSec: Double?
        let durationSec: Double?
        let readyState: Double?
        let muted: Bool
    }
    let available: Bool
    let reason: String?
    /// "playing", "paused" or "idle" (only when available).
    let status: String?
    let audible: Bool?
    let muted: Bool?
    let mediaSession: MediaSession?
    let element: MediaElement?
}

// MARK: Runtime state, events, errors

nonisolated enum ECSRuntimeState: Sendable, Equatable {
    case stopped
    case starting
    case ready
    case stopping
    case crashed(exitCode: Int32)
    case failed(String)
}

nonisolated enum ECSRuntimeEvent: Sendable {
    case stateChanged(ECSRuntimeState)
    /// Asynchronous event pushed by the runtime, e.g. "playback.changed", "auth.changed", "runtime.exiting".
    case runtimeEvent(name: String, data: JSONValue)
    /// Diagnostics: runtime stderr lines and bridge notices. Never part of the protocol.
    case log(String)
}

nonisolated enum ECSRuntimeError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case duplicateRuntimeInstance
    case notRunning
    case launchFailed(String)
    case readyTimeout
    case timeout(command: String)
    case processTerminated(exitCode: Int32)
    case remote(code: String, message: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "An ECS runtime is already running or starting."
        case .duplicateRuntimeInstance: return "Another ECS runtime already owns the Spotify profile."
        case .notRunning: return "The ECS runtime is not running."
        case .launchFailed(let why): return "Could not launch the ECS runtime: \(why)"
        case .readyTimeout: return "The ECS runtime did not become ready in time."
        case .timeout(let command): return "ECS command \"\(command)\" timed out."
        case .processTerminated(let code): return "The ECS runtime exited (code \(code))."
        case .remote(let code, let message): return "ECS runtime error \(code): \(message)"
        case .malformedResponse: return "The ECS runtime sent an unusable response."
        }
    }
}

// MARK: Configuration

nonisolated struct ECSRuntimeConfiguration: Sendable {
    var executableURL: URL
    var arguments: [String]
    var workingDirectory: URL?
    /// nil inherits the app's environment. ELECTRON_RUN_AS_NODE is always removed.
    var environment: [String: String]?
    /// First launch can be slow (Widevine component download), so this is generous.
    var readyTimeout: TimeInterval = 90
    var defaultCommandTimeout: TimeInterval = 10
    /// How long to wait after the shutdown command before SIGTERM (then SIGKILL).
    var shutdownGracePeriod: TimeInterval = 5
    /// Automatic restarts after a crash of a ready runtime (linear backoff: 1 s, 2 s, ...). 0 disables.
    var maxAutomaticRestarts: Int = 0

    /// Development layout: runs `<appDirectory>/node_modules/electron/...` with `--bridge --clean-ua`.
    /// appDirectory is experiments/spotify-ecs after `npm install`. The clean User-Agent is required for
    /// Spotify to serve the desktop web player, so it is part of the default arguments.
    static func development(appDirectory: URL, freshSession: Bool = false) -> ECSRuntimeConfiguration {
        let electronDir = appDirectory.appendingPathComponent("node_modules/electron", isDirectory: true)
        // The electron npm package records its binary's relative path in path.txt.
        let relative = (try? String(contentsOf: electronDir.appendingPathComponent("path.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let binary = electronDir.appendingPathComponent("dist/" + (relative?.isEmpty == false ? relative! : "Electron.app/Contents/MacOS/Electron"))
        var args = [appDirectory.path, "--bridge", "--clean-ua"]
        if freshSession { args.append("--fresh-session") }
        return ECSRuntimeConfiguration(executableURL: binary, arguments: args, workingDirectory: appDirectory)
    }
}
