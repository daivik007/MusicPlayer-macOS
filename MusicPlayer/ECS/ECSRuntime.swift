import Foundation
#if canImport(OSLog)
import OSLog
#endif

// M4B: owns the ECS (Electron) child process and speaks NDJSON over its stdin/stdout.
// Headless by design: no UI, no dependency on LibraryManager/AudioEngine. Local playback is untouched.
//
// Requires the app to be allowed to launch an external executable: this does NOT work under the App Sandbox
// (see experiments/spotify-ecs/README.md, "Sandbox").

/// Process-wide guard: at most one runtime instance may be starting or running. (The Electron side adds a
/// single-instance lock on the profile directory, so a second *process* is refused too.)
nonisolated final class ECSInstanceGuard: @unchecked Sendable {
    static let shared = ECSInstanceGuard()
    private let lock = NSLock()
    private var owner: UUID?

    func claim(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return false }
        owner = id
        return true
    }
    func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == id { owner = nil }
    }
}

actor ECSRuntime {
    /// Single-consumer stream of state changes, runtime events and diagnostics.
    nonisolated let events: AsyncStream<ECSRuntimeEvent>

    private(set) var state: ECSRuntimeState = .stopped

    private let eventContinuation: AsyncStream<ECSRuntimeEvent>.Continuation
    private let configuration: ECSRuntimeConfiguration
    #if canImport(OSLog)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicPlayer", category: "ECS")
    #endif

    private var process: Process?
    private var instanceID: UUID?
    private var stdinHandle: FileHandle?
    private var generation = 0
    private var shutdownTask: Task<Void, Never>?
    private var shutdownState: ECSRuntimeState?
    private var pending: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var readyContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var readerTasks: [Task<Void, Never>] = []
    private var restartTask: Task<Void, Never>?
    private var automaticRestartsUsed = 0

    init(configuration: ECSRuntimeConfiguration) {
        self.configuration = configuration
        let (stream, continuation) = AsyncStream.makeStream(of: ECSRuntimeEvent.self, bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.eventContinuation = continuation
    }

    deinit {
        // The runtime exits on stdin EOF. Its termination handler then releases the guard.
        try? stdinHandle?.close()
        readerTasks.forEach { $0.cancel() }
        restartTask?.cancel()
        eventContinuation.finish()
    }

    // MARK: Lifecycle

    /// Launches the runtime and returns once it reports `runtime.ready` (Spotify's document has loaded).
    func start() async throws {
        try await begin(manual: true)
    }

    /// Graceful stop: `shutdown` command, then SIGTERM, then SIGKILL. Safe to call in any state.
    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        if let shutdownTask {
            if process == nil { setState(.stopped) }
            else { shutdownState = .stopped }
            await shutdownTask.value
        } else if process != nil {
            await shutDown(final: .stopped, graceful: true)
        } else {
            setState(.stopped)
        }
    }

    func restart() async throws {
        await stop()
        try await start()
    }

    // MARK: Commands

    /// Sends a command and awaits its response (matched by request id). Throws `.timeout`, `.remote`, or
    /// `.processTerminated` if the runtime dies first.
    @discardableResult
    func send(_ command: String, args: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> JSONValue {
        guard state == .ready || state == .starting else { throw ECSRuntimeError.notRunning }
        return try await sendInternal(command, args: args, timeout: timeout)
    }

    func ping() async throws -> JSONValue { try await send("ping") }
    func runtimeStatus() async throws -> JSONValue { try await send("runtime.status") }
    func authStatus() async throws -> ECSAuthStatus { try decode(ECSAuthStatus.self, try await send("auth.status")) }
    func playbackState() async throws -> ECSPlaybackState { try decode(ECSPlaybackState.self, try await send("playback.state")) }

    func setMuted(_ muted: Bool) async throws -> Bool {
        let result = try await send("playback.setMuted", args: ["muted": .bool(muted)])
        return try decode(ECSMuteResult.self, result).muted
    }

    // MARK: Start-up

    private func begin(manual: Bool = false) async throws {
        try Task.checkCancellation()
        guard process == nil, shutdownTask == nil else { throw ECSRuntimeError.alreadyRunning }
        let owner = UUID()
        guard ECSInstanceGuard.shared.claim(owner) else { throw ECSRuntimeError.alreadyRunning }
        instanceID = owner
        if manual {
            restartTask?.cancel()
            restartTask = nil
            automaticRestartsUsed = 0
        }
        setState(.starting)

        signal(SIGPIPE, SIG_IGN) // a dead child must surface as a write error, never kill the app

        let exe = configuration.executableURL
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            let reason = "Executable not found at \(exe.path). Run `npm install` in experiments/spotify-ecs."
            setState(.failed(reason))
            releaseInstance()
            throw ECSRuntimeError.launchFailed(reason)
        }

        let p = Process()
        p.executableURL = exe
        p.arguments = configuration.arguments
        p.currentDirectoryURL = configuration.workingDirectory
        var env = configuration.environment ?? ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE") // would turn Electron into plain Node
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        generation += 1
        let gen = generation
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task {
                if let self {
                    await self.handleTermination(generation: gen, status: status)
                } else {
                    ECSInstanceGuard.shared.release(owner)
                }
            }
        }

        do { try p.run() } catch {
            let reason = error.localizedDescription
            setState(.failed(reason))
            releaseInstance()
            throw ECSRuntimeError.launchFailed(reason)
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        readerTasks = [
            Task { [weak self] in
                do {
                    try await ECSPipeReader.readLines(from: outHandle) { [weak self] line in
                        await self?.handleStdoutLine(line, generation: gen)
                    }
                } catch {
                    await self?.handleStderrLine("stdout read failed: \(error.localizedDescription)", generation: gen)
                }
            },
            Task { [weak self] in
                do {
                    try await ECSPipeReader.readLines(from: errHandle) { [weak self] line in
                        await self?.handleStderrLine(line, generation: gen)
                    }
                } catch {
                    await self?.handleStderrLine("stderr read failed: \(error.localizedDescription)", generation: gen)
                }
            }
        ]

        let (readyStream, readyCont) = AsyncThrowingStream<Void, Error>.makeStream()
        readyContinuation = readyCont
        let limit = configuration.readyTimeout
        let timer = Task {
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            readyCont.finish(throwing: ECSRuntimeError.readyTimeout)
        }
        defer { timer.cancel() }

        do {
            var iterator = readyStream.makeAsyncIterator()
            let ready: Void? = try await iterator.next()
            try Task.checkCancellation()
            guard ready != nil, gen == generation, state == .ready, p.isRunning else {
                throw ECSRuntimeError.notRunning
            }
        } catch {
            if gen == generation, shutdownState == nil {
                await shutDown(final: .failed(error.localizedDescription), graceful: false)
            }
            throw error
        }
    }

    private func shutDown(final: ECSRuntimeState, graceful: Bool) async {
        guard let p = process else { return }
        let gen = generation
        shutdownState = final
        setState(.stopping)
        readyContinuation?.finish(throwing: ECSRuntimeError.notRunning)
        readyContinuation = nil

        // Every caller waits on the same task. Cancelling a caller cannot cancel child cleanup.
        let task = Task {
            if graceful {
                _ = try? await sendInternal("shutdown", args: [:], timeout: 2)
                await waitForExit(p, timeout: configuration.shutdownGracePeriod)
            }
            if p.isRunning {
                p.terminate()
                await waitForExit(p, timeout: 3)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                await waitForExit(p, timeout: 2)
            }
            // The termination callback may already have performed teardown.
            if !p.isRunning {
                handleTermination(generation: gen, status: p.terminationStatus)
            }
            shutdownTask = nil
        }
        shutdownTask = task
        await task.value
    }

    // MARK: Incoming data

    private func handleStdoutLine(_ line: String, generation gen: Int) {
        guard gen == generation else { return }
        guard !line.isEmpty,
              let msg = try? JSONDecoder().decode(ECSIncomingMessage.self, from: Data(line.utf8)), msg.v == 1 else {
            emit(.log("ignored non-protocol stdout line (\(line.count) chars)"))
            return
        }
        if let id = msg.id {
            guard let cont = pending.removeValue(forKey: id) else { return }
            timeouts.removeValue(forKey: id)?.cancel()
            if msg.ok == true {
                cont.yield(msg.result ?? .null)
                cont.finish()
            } else {
                let err = msg.error
                cont.finish(throwing: ECSRuntimeError.remote(code: err?.code ?? "unknown", message: err?.message ?? ""))
            }
        } else if let name = msg.event {
            handleEvent(name: name, data: msg.data ?? .null)
        } else if msg.ok == false {
            emit(.log("runtime rejected a malformed line: \(msg.error?.code ?? "unknown")"))
        }
    }

    private func handleEvent(name: String, data: JSONValue) {
        switch name {
        case "runtime.ready":
            if state == .starting {
                // A timeout or cancellation may already have closed the readiness stream.
                if case .enqueued? = readyContinuation?.yield(()) { setState(.ready) }
                readyContinuation?.finish()
                readyContinuation = nil
            }
        case "runtime.error":
            let code = data["code"]?.stringValue
            let message = data["message"]?.stringValue ?? "runtime error"
            if code == "duplicate_instance" {
                readyContinuation?.finish(throwing: ECSRuntimeError.duplicateRuntimeInstance)
            } else if state == .starting {
                readyContinuation?.finish(throwing: ECSRuntimeError.launchFailed(message))
            }
            readyContinuation = nil
        default: break
        }
        emit(.runtimeEvent(name: name, data: data))
    }

    private func handleStderrLine(_ line: String, generation gen: Int) {
        guard gen == generation else { return }
        #if canImport(OSLog)
        logger.debug("ecs: \(line, privacy: .private)")
        #endif
        emit(.log(line))
    }

    // MARK: Termination and recovery

    private func handleTermination(generation gen: Int, status: Int32) {
        guard gen == generation else { return }
        let previous = state
        let error = ECSRuntimeError.processTerminated(exitCode: status)
        failAllPending(error)
        // The exit callback can arrive before stdout delivers runtime.error.
        readyContinuation?.finish(throwing: status == 73 ? ECSRuntimeError.duplicateRuntimeInstance : error)
        readyContinuation = nil
        let expected = shutdownState != nil || (status == 0 && previous == .ready)
        teardown(final: shutdownState ?? (expected ? .stopped : .crashed(exitCode: status)))
        if !expected && previous == .ready { scheduleAutomaticRestart() }
    }

    private func scheduleAutomaticRestart() {
        guard automaticRestartsUsed < configuration.maxAutomaticRestarts else { return }
        automaticRestartsUsed += 1
        let delay = Double(automaticRestartsUsed)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.automaticRestart()
        }
    }

    private func automaticRestart() async {
        guard !Task.isCancelled else { return }
        restartTask = nil
        do { try await begin() } catch { emit(.log("automatic restart failed: \(error.localizedDescription)")) }
    }

    /// Releases every process resource and moves to a terminal state. Idempotent.
    private func teardown(final newState: ECSRuntimeState) {
        generation += 1
        shutdownState = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
        readerTasks.forEach { $0.cancel() }
        readerTasks = []
        readyContinuation?.finish(throwing: ECSRuntimeError.notRunning) // unblocks a start() still waiting
        readyContinuation = nil
        failAllPending(ECSRuntimeError.notRunning)
        releaseInstance()
        setState(newState)
    }

    private func releaseInstance() {
        guard let instanceID else { return }
        ECSInstanceGuard.shared.release(instanceID)
        self.instanceID = nil
    }

    private func waitForExit(_ p: Process, timeout: TimeInterval) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while p.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Request plumbing

    private func sendInternal(_ command: String, args: [String: JSONValue], timeout: TimeInterval?) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let handle = stdinHandle else { throw ECSRuntimeError.notRunning }
        let id = UUID().uuidString
        var payload = try JSONEncoder().encode(ECSRequestEnvelope(v: 1, id: id, cmd: command, args: args))
        payload.append(0x0A)

        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        pending[id] = continuation
        let limit = timeout ?? configuration.defaultCommandTimeout
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            await self?.expire(id: id, command: command)
        }
        defer { clear(id) }
        do { try handle.write(contentsOf: payload) } catch {
            throw ECSRuntimeError.notRunning
        }
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        if let value { return value }
        throw ECSRuntimeError.malformedResponse
    }

    private func expire(id: String, command: String) {
        timeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.finish(throwing: ECSRuntimeError.timeout(command: command))
    }

    private func clear(_ id: String) {
        pending.removeValue(forKey: id)
        timeouts.removeValue(forKey: id)?.cancel()
    }

    private func failAllPending(_ error: Error) {
        let all = pending
        pending = [:]
        timeouts.values.forEach { $0.cancel() }
        timeouts = [:]
        for (_, continuation) in all { continuation.finish(throwing: error) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)) }
        catch { throw ECSRuntimeError.malformedResponse }
    }

    private func setState(_ new: ECSRuntimeState) {
        guard new != state else { return }
        state = new
        emit(.stateChanged(new))
    }

    private func emit(_ event: ECSRuntimeEvent) { eventContinuation.yield(event) }

    #if DEBUG
    /// Test hooks (DEBUG only): inject a raw protocol line, or simulate a crash.
    func debugSendRawLine(_ line: String) throws {
        guard let handle = stdinHandle, let data = (line + "\n").data(using: .utf8) else { throw ECSRuntimeError.notRunning }
        try handle.write(contentsOf: data)
    }
    func debugKillProcess() {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    #endif
}
