import Foundation
import Observation

/// Coordinates the selected provider. The local queue and engine stay owned by the local player.
@MainActor @Observable
final class PlaybackController {
    enum Source { case local, spotify }

    private(set) var source: Source = .local
    private(set) var connection: ECSRuntimeState = .stopped
    private(set) var snapshot: ECSPlaybackState?
    private(set) var muted: Bool?
    private(set) var errorMessage: String?
    private(set) var actionError: String?
    private(set) var switchingToLocal = false
    private(set) var changingMute = false

    @ObservationIgnored private let runtime: ECSRuntime?
    @ObservationIgnored private var startupTask: Task<Void, Error>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var connectionAttempt = 0

    init(runtime: ECSRuntime?) {
        self.runtime = runtime
    }

    var spotifyConfigured: Bool { runtime != nil }
    var shouldShutDown: Bool { source == .spotify }

    var canConnect: Bool {
        guard spotifyConfigured, source == .spotify, !switchingToLocal else { return false }
        switch connection {
        case .stopped, .crashed, .failed: return true
        case .starting, .ready, .stopping: return false
        }
    }

    var canSetMuted: Bool {
        connection == .ready && !switchingToLocal && !changingMute &&
            snapshot?.available == true && snapshot?.capabilities?.canSetMuted == true && muted != nil
    }

    func selectSpotify(pauseLocal: () -> Void) async {
        guard spotifyConfigured, source == .local else { return }
        pauseLocal()
        source = .spotify
        await connect()
    }

    func connect() async {
        guard canConnect, let runtime else { return }
        clearSnapshot()
        connectionAttempt += 1
        let attempt = connectionAttempt
        errorMessage = nil
        actionError = nil
        connection = .starting
        observe(runtime)
        let startup = Task { try await runtime.start() }
        startupTask = startup
        defer {
            if connectionAttempt == attempt { startupTask = nil }
        }

        do {
            try await startup.value
            let current = await runtime.state
            guard connectionAttempt == attempt, !switchingToLocal, source == .spotify else { return }
            updateConnection(current)
        } catch {
            let current = await runtime.state
            guard connectionAttempt == attempt, !switchingToLocal, source == .spotify else { return }
            updateConnection(current)
            errorMessage = error.localizedDescription
        }
    }

    func selectLocal() async {
        guard source == .spotify, !switchingToLocal, let runtime else { return }
        switchingToLocal = true
        connectionAttempt += 1
        clearSnapshot()
        connection = .stopping
        await stopRuntime()
        let current = await runtime.state
        switchingToLocal = false
        connection = current
        if current == .stopped {
            errorMessage = nil
            actionError = nil
            source = .local
        } else {
            errorMessage = "Spotify is still closing. Close the Spotify window and try again."
        }
    }

    func shutDownForTermination() async {
        connectionAttempt += 1
        switchingToLocal = true
        clearSnapshot()
        eventsTask?.cancel()
        eventsTask = nil
        await stopRuntime()
    }

    private func stopRuntime() async {
        let startup = startupTask
        startupTask = nil
        startup?.cancel()
        await runtime?.stop()
        _ = try? await startup?.value
    }

    func toggleOutputMute() async {
        guard let runtime, canSetMuted, let muted else { return }
        let attempt = revision
        changingMute = true
        actionError = nil
        // Drop any state reply that began before the mute request.
        refreshTask?.cancel()
        refreshTask = nil
        defer {
            if revision == attempt {
                changingMute = false
                refresh()
            }
        }
        do {
            let confirmed = try await runtime.setMuted(!muted)
            if revision == attempt { self.muted = confirmed }
        } catch {
            if revision == attempt { actionError = error.localizedDescription }
        }
    }

    private func observe(_ runtime: ECSRuntime) {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            for await event in runtime.events {
                guard let self else { return }
                guard self.source == .spotify, !self.switchingToLocal else { continue }
                switch event {
                case .stateChanged:
                    // The consumer can lag the actor during a rapid stop and reconnect.
                    let current = await runtime.state
                    guard self.source == .spotify, !self.switchingToLocal else { continue }
                    self.updateConnection(current)
                case .runtimeEvent(let name, _):
                    if name == "playback.changed" || name == "auth.changed" { self.refresh() }
                case .log:
                    break
                }
            }
        }
    }

    private func updateConnection(_ state: ECSRuntimeState) {
        if state != connection {
            connection = state
            if state != .ready { clearSnapshot() }
        }

        if state == .ready, pollingTask == nil {
            errorMessage = nil
            refresh()
            // MediaSession metadata has no change event. Browser events handle immediate updates.
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.refresh()
                }
            }
        }
    }

    private func refresh() {
        guard let runtime, source == .spotify, connection == .ready,
              !switchingToLocal, !changingMute, refreshTask == nil else { return }
        let attempt = revision
        refreshTask = Task { [weak self] in
            let result: Result<ECSPlaybackState, Error>
            do { result = .success(try await runtime.playbackState()) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.revision == attempt else { return }
            self.refreshTask = nil
            switch result {
            case .success(let state):
                if self.snapshot != state { self.snapshot = state }
                self.muted = state.available ? state.muted : nil
                self.errorMessage = nil
            case .failure(let error):
                self.snapshot = nil
                self.muted = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func clearSnapshot() {
        revision += 1
        refreshTask?.cancel()
        refreshTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        snapshot = nil
        muted = nil
        changingMute = false
    }

    deinit {
        startupTask?.cancel()
        eventsTask?.cancel()
        refreshTask?.cancel()
        pollingTask?.cancel()
    }
}
