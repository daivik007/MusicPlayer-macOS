#if DEBUG
import Foundation
import OSLog

// M4B: opt-in developer smoke test. Does nothing unless MUSICPLAYER_ECS_SMOKE_DIR points at experiments/spotify-ecs.
// Needs a build where the App Sandbox is off (see experiments/spotify-ecs/README.md). Results print to the Xcode
// console and the unified log (subsystem = bundle id, category "ECS"). It never touches local playback or the UI.
enum ECSDebugSmoke {
    static func runIfRequested() async {
        guard let dir = ProcessInfo.processInfo.environment["MUSICPLAYER_ECS_SMOKE_DIR"] else { return }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("[ECS smoke] \(ok ? "PASS" : "FAIL") \(name) \(detail)")
        }

        let config = ECSRuntimeConfiguration.development(appDirectory: URL(fileURLWithPath: dir, isDirectory: true))
        let runtime = ECSRuntime(configuration: config)
        let eventTask = Task {
            for await event in runtime.events {
                switch event {
                case .stateChanged(let s): print("[ECS smoke] state -> \(s)")
                case .runtimeEvent(let name, _): print("[ECS smoke] event \(name)")
                case .log: break
                }
            }
        }
        defer { eventTask.cancel() }

        do {
            try await runtime.start()
            check("start reaches ready", await runtime.state == .ready)
        } catch {
            check("start", false, error.localizedDescription)
            print("[ECS smoke] \(failures) failure(s). If this is a sandbox error, see experiments/spotify-ecs/README.md.")
            return
        }

        do { let r = try await runtime.ping(); check("ping", r["pong"]?.boolValue == true) } catch { check("ping", false, "\(error)") }
        do { let r = try await runtime.runtimeStatus(); check("runtime.status clean UA", r["uaMode"]?.stringValue == "clean-chromium", "\(r)") } catch { check("runtime.status", false, "\(error)") }
        var auth = "unknown"
        do { let a = try await runtime.authStatus(); auth = a.state; check("auth.status", ["signed-in", "signed-out"].contains(a.state), a.state) } catch { check("auth.status", false, "\(error)") }
        do { let p = try await runtime.playbackState(); check("playback.state", p.available, "status=\(p.status ?? "-") audible=\(p.audible.map(String.init) ?? "-") t=\(p.element?.currentTimeSec.map(String.init) ?? "-")") } catch { check("playback.state", false, "\(error)") }

        // Remote error path and malformed input must not break the session.
        do { _ = try await runtime.send("no.such.command"); check("unknown command rejected", false) }
        catch ECSRuntimeError.remote(let code, _) { check("unknown command rejected", code == "unknown_command", code) }
        catch { check("unknown command rejected", false, "\(error)") }
        try? await runtime.debugSendRawLine("this is not json")
        try? await runtime.debugSendRawLine("{\"cmd\":\"ping\"}")
        do { _ = try await runtime.ping(); check("responsive after malformed input", true) } catch { check("responsive after malformed input", false, "\(error)") }

        // Duplicate instance prevention.
        do { try await ECSRuntime(configuration: config).start(); check("second runtime refused", false) }
        catch ECSRuntimeError.alreadyRunning { check("second runtime refused", true) }
        catch { check("second runtime refused", false, "\(error)") }

        // Crash and recovery, then session persistence across the restart.
        await runtime.debugKillProcess()
        var crashed = false
        for _ in 0..<50 {
            let s = await runtime.state
            if case .crashed = s { crashed = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("crash detected", crashed)
        var failedFast = false
        do { _ = try await runtime.ping() } catch ECSRuntimeError.notRunning { failedFast = true } catch {}
        check("commands fail fast when crashed", failedFast)
        try? await Task.sleep(for: .seconds(1.5)) // let Chromium helpers exit and release the profile lock
        do {
            try await runtime.start()
            let a2 = try await runtime.authStatus()
            check("recovered; session persisted", a2.state == auth, "\(auth) -> \(a2.state)")
        } catch { check("recovery", false, error.localizedDescription) }

        await runtime.stop()
        check("clean shutdown", await runtime.state == .stopped)
        print("[ECS smoke] done, \(failures) failure(s)")
    }
}
#endif
