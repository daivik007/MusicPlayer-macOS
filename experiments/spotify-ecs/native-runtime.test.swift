import Foundation

@main
enum ECSRuntimeTests {
    enum Failure: Error {
        case check(String)
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { throw Failure.check("Expected absolute Node and fixture paths") }
        let node = URL(fileURLWithPath: arguments[1])
        let fixture = arguments[2]
        func makeRuntime(_ mode: String, readyTimeout: TimeInterval = 5) -> ECSRuntime {
            var config = ECSRuntimeConfiguration(executableURL: node, arguments: [fixture, mode])
            config.readyTimeout = readyTimeout
            return ECSRuntime(configuration: config)
        }

        let runtime = makeRuntime("slow-shutdown")
        let collector = EventCollector(runtime.events)
        try await runtime.start()
        try await collector.waitFor("runtime.ready")
        async let slow = runtime.send("slow")
        async let ping = runtime.ping()
        try await check(ping["pong"]?.boolValue == true, "ping result")
        try await check(slow["slow"]?.boolValue == true, "slow result")
        let auth = try await runtime.authStatus()
        try check(auth.state == "signed-in" && auth.verified == false, "typed authentication status")
        let playback = try await runtime.playbackState()
        try check(playback.audible == true && playback.mediaSession?.title == "Fixture track" && playback.element == nil,
                  "typed playback status with unavailable position")

        let command = Task { try await runtime.send("hang") }
        try await collector.waitFor("test.command-pending")
        command.cancel()
        do {
            _ = try await command.value
            throw Failure.check("Cancelled command returned a result")
        } catch is CancellationError {}

        do {
            _ = try await runtime.send("hang", timeout: 0.1)
            throw Failure.check("Unanswered command did not time out")
        } catch ECSRuntimeError.timeout(command: "hang") {}

        let firstStop = Task { await runtime.stop() }
        try await collector.waitFor("test.shutdown-pending")
        let secondStop = Task { await runtime.stop() }
        do {
            try await runtime.start()
            throw Failure.check("A second start was allowed during shutdown")
        } catch ECSRuntimeError.alreadyRunning {}
        firstStop.cancel()
        await firstStop.value
        await secondStop.value
        try await check(runtime.state == .stopped, "Both stop calls should await cleanup")
        try await runtime.start()
        try await check(runtime.ping()["pong"]?.boolValue == true, "Restart after overlapping stops")

        await collector.clear("test.command-pending")
        let pendingAtCrash = Task { try await runtime.send("hang") }
        try await collector.waitFor("test.command-pending")
        await runtime.debugKillProcess()
        do {
            _ = try await pendingAtCrash.value
            throw Failure.check("Pending command succeeded after crash")
        } catch ECSRuntimeError.processTerminated {}
        try await runtime.start()
        await runtime.stop()
        print("PASS requests, cancellation, timeout, overlapping shutdown, crash and restart")

        let slowStartup = makeRuntime("slow-ready")
        let startupEvents = EventCollector(slowStartup.events)
        let cancelledStart = Task { try await slowStartup.start() }
        try await startupEvents.waitFor("runtime.starting")
        cancelledStart.cancel()
        do {
            try await cancelledStart.value
            throw Failure.check("Cancelled startup succeeded")
        } catch is CancellationError {}
        await startupEvents.clear("runtime.starting")
        let stoppedStart = Task { try await slowStartup.start() }
        try await startupEvents.waitFor("runtime.starting")
        await slowStartup.stop()
        do {
            try await stoppedStart.value
            throw Failure.check("Startup succeeded despite stop")
        } catch ECSRuntimeError.notRunning {}
        try await slowStartup.start()
        await slowStartup.stop()
        print("PASS cancelled startup, stop during startup and subsequent start")

        let stalled = makeRuntime("ignore-term", readyTimeout: 0.75)
        let stalledEvents = EventCollector(stalled.events)
        let stuckStart = Task { try await stalled.start() }
        let starting = try await stalledEvents.waitFor("runtime.starting")
        guard let pid = starting["pid"]?.doubleValue else { throw Failure.check("Missing child PID") }
        try await waitUntilStopping(stalled)
        do {
            try await runtime.start()
            throw Failure.check("Another actor claimed the guard during startup cleanup")
        } catch ECSRuntimeError.alreadyRunning {}
        do {
            try await stuckStart.value
            throw Failure.check("Stalled startup succeeded")
        } catch ECSRuntimeError.readyTimeout {}
        try check(kill(Int32(pid), 0) == -1 && errno == ESRCH, "Startup timeout must reap the child before returning")
        try await runtime.start()
        await runtime.stop()
        print("PASS readiness timeout, kill fallback and guard retention")

        let duplicate = makeRuntime("duplicate")
        do {
            try await duplicate.start()
            throw Failure.check("Exit 73 was accepted as a successful startup")
        } catch ECSRuntimeError.duplicateRuntimeInstance {}
        print("PASS duplicate-instance exit mapping")

        var dropped: ECSRuntime? = makeRuntime("slow-shutdown")
        try await dropped?.start()
        dropped = nil
        for _ in 0..<500 {
            do {
                try await runtime.start()
                await runtime.stop()
                print("PASS dropping the runtime closes stdin and releases the guard")
                return
            } catch ECSRuntimeError.alreadyRunning {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw Failure.check("A dropped runtime still holds the instance guard")
    }

    static func check(_ result: Bool, _ message: String) throws {
        if !result { throw Failure.check(message) }
    }

    static func waitUntilStopping(_ runtime: ECSRuntime) async throws {
        for _ in 0..<500 {
            if await runtime.state == .stopping { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.check("Readiness timeout did not start cleanup")
    }
}

actor EventCollector {
    private var received: [String: JSONValue] = [:]
    private var reader: Task<Void, Never>?

    init(_ events: AsyncStream<ECSRuntimeEvent>) {
        Task { await collect(events) }
    }

    private func collect(_ events: AsyncStream<ECSRuntimeEvent>) {
        reader = Task { [weak self] in
            for await event in events {
                if case .runtimeEvent(let name, let data) = event {
                    await self?.record(name, data: data)
                }
            }
        }
    }

    deinit { reader?.cancel() }

    private func record(_ name: String, data: JSONValue) { received[name] = data }

    func clear(_ name: String) { received[name] = nil }

    @discardableResult
    func waitFor(_ name: String) async throws -> JSONValue {
        for _ in 0..<500 {
            if let data = received[name] { return data }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ECSRuntimeTests.Failure.check("Missing event \(name)")
    }
}
