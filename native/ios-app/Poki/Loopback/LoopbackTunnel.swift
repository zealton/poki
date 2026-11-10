import Foundation
import NetworkExtension
import PokiCore

@MainActor
@Observable
final class LoopbackTunnel {
    enum State: Equatable {
        case unavailable, off, connecting, connected, disconnecting
        case failed(String)
    }
    private(set) var state: State = .off {
        didSet { if state != oldValue { AppLog.shared.add("loopback", "local VPN: \(state)") } }
    }
    private(set) var busy = false
    private var manager: NETunnelProviderManager?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored private var connectionDeadline: Task<Void, Never>?
    /// After the tunnel failed or dropped without the owner ending it, dial again with a backoff and a
    /// cap (GitHub issue 44: it stayed down for 101 s and 134 s until someone opened Poki). The
    /// owner's own Disconnect, or Turn off, ends it for good until they connect again; so does another
    /// VPN being detected when a try comes (best effort: a VPN that sets no proxy, such as Tailscale, may not be detected). Opening Poki dials nothing.
    private var reconnect = ReconnectPlan()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    private var reconnecting = false
    /// When Poki itself last stopped the tunnel. The tunnel hears that as a stop by the user, and its
    /// "stopped on purpose" notification must not cancel the retry Poki queued right after.
    private var stoppedByAppAt: Date?
    /// The owner pressed Disconnect while a connection was still being brought up: stop it when that ends.
    private var stopAfterBringUp = false
    /// Whether Poki is on and needs the local connection; the app model answers.
    var wanted: () -> Bool = { false }
    /// The tunnel is up again after an automatic reconnect; the app checks the loopback at once.
    var onReconnected: (() -> Void)?
    /// Something the owner has to see: Poki did not dial because another VPN is on. nil when it is over.
    var onAttention: ((String?) -> Void)?

    // Read the embedded id: signing tools can rewrite bundle identifiers.
    private let providerID: String? = {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return nil }
        return Bundle(url: plugins.appendingPathComponent("PokiTunnel.appex"))?.bundleIdentifier
    }()

    var available: Bool { providerID != nil }
    var connected: Bool { state == .connected }

    init() {
        if !available { state = .unavailable }
        listenForEndedOnPurpose()
        statusObserver = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let connection = notification.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.updateStatus()
            }
        }
    }

    // Cleanup uses thread-safe cancellation and observer removal, not UI state. Avoid the Swift
    // isolated-deinit back-deployment path that aborts in TaskLocal::StopLookupScope on iOS 26.2
    // during synchronous destruction (swiftlang/swift#85663). These tokens need no observation.
    nonisolated deinit {
        connectionDeadline?.cancel()
        reconnectTask?.cancel()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    func refresh() async {
        #if !targetEnvironment(simulator)
        guard available, !busy else { return }
        busy = true
        defer { busy = false }
        do { manager = try await savedManager(); updateStatus() }
        catch { state = .failed("Cannot read Poki's VPN configuration. Try again, or choose an external connection.") }
        #endif
    }

    /// Called only after the owner chooses Poki's local VPN, never while using an external proxy.
    func connect() async throws {
        reconnect.ownerStarted()
        try await bringUp()
    }

    private func bringUp() async throws {
        #if targetEnvironment(simulator)
        let message = "The local VPN needs a physical iPhone. Its network connection cannot be tested in the Simulator."
        state = .failed(message)
        throw failure(message)
        #else
        guard let providerID else { throw failure("This build has no local VPN. Choose an external connection, or install the build with the local VPN and supported signing.") }
        guard !busy else { throw failure("A local connection change is already in progress. Try again when it finishes.") }
        busy = true
        defer { busy = false; stopAfterBringUp = false }
        do {
            let manager = try await savedManager() ?? NETunnelProviderManager()
            try Task.checkCancellation()
            self.manager = manager
            if manager.connection.status == .connected || manager.connection.status == .connecting || manager.connection.status == .reasserting {
                updateStatus()
                return
            }
            guard manager.connection.status != .disconnecting else { throw failure("The local connection is still stopping. Try again in a moment.") }
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = providerID
            configuration.serverAddress = "On this iPhone"
            configuration.disconnectOnSleep = false
            configuration.includeAllNetworks = false
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "Poki local connection"
            manager.isEnabled = true
            // Never on demand: iOS must not bring Poki's tunnel up by itself (it could displace another VPN).
            // Only the owner's connect, or Poki's own retry after its tunnel failed, dials it.
            manager.isOnDemandEnabled = false
            state = .connecting
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try Task.checkCancellation()
            try manager.connection.startVPNTunnel()
            updateStatus()
            if stopAfterBringUp { stopNow(manager); return }
            connectionDeadline?.cancel()
            connectionDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.state == .connecting else { return }
                self.stoppedByAppAt = Date()
                self.manager?.connection.stopVPNTunnel()
                self.state = .failed("The local VPN did not connect within 15 seconds. Try again, or choose an external connection.")
                self.scheduleReconnect(because: "it did not connect within 15 seconds")
            }
        } catch is CancellationError {
            updateStatus()
            throw CancellationError()
        } catch {
            let message = "Could not start Poki's local VPN. Allow the VPN configuration when asked. If signing does not include Network Extensions, use the external-connection build with LocalDevVPN or a compatible proxy."
            state = .failed(message)
            throw failure(message)
        }
        #endif
    }

    func disconnect() {
        reconnect.ownerStopped()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
        // A connection still being brought up cannot be stopped yet; it is stopped when that ends.
        if busy { stopAfterBringUp = true; return }
        guard let manager else { return }
        stopNow(manager)
    }

    private func stopNow(_ manager: NETunnelProviderManager) {
        connectionDeadline?.cancel()
        guard manager.connection.status != .disconnected, manager.connection.status != .invalid else { updateStatus(); return }
        state = .disconnecting
        stoppedByAppAt = Date()
        manager.connection.stopVPNTunnel()
    }

    private func savedManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
    }

    private func updateStatus() {
        guard available else { state = .unavailable; return }
        switch manager?.connection.status ?? .invalid {
        case .connected:
            connectionDeadline?.cancel()
            state = .connected
            reconnect.connected()
            onAttention?(nil)
            if reconnecting { reconnecting = false; onReconnected?() }
        case .connecting, .reasserting: state = .connecting
        case .disconnecting: state = .disconnecting
        case .invalid, .disconnected:
            if busy && state == .connecting { return }
            connectionDeadline?.cancel()
            if state == .connecting || state == .connected {
                state = .failed("The local VPN disconnected. Reconnect here. If it keeps stopping, check that both Poki and its tunnel were signed with Network Extensions, or choose an external connection.")
                logStopReason()
                scheduleReconnect(because: "the local VPN disconnected")
            } else if case .failed = state {
                return
            } else { state = .off }
        @unknown default: state = .off
        }
    }

    /// The tunnel posts this (a Darwin notification, no payload; named by `TunnelStopSignal`) when the
    /// owner turned it off in Settings or another VPN took over. Poki then leaves it down until the
    /// owner connects it again.
    private func listenForEndedOnPurpose() {
        guard let providerID else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let tunnel = Unmanaged<LoopbackTunnel>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in tunnel.endedOnPurpose() }
        }, (providerID + TunnelStopSignal.suffix) as CFString, nil, .deliverImmediately)
    }

    private func endedOnPurpose() {
        // Poki's own stop (the 15 s try that did not connect, or the owner's Disconnect) is told as a stop by
        // the user too. For the first the retry stands; for the second nothing is queued anyway.
        if let at = stoppedByAppAt, Date().timeIntervalSince(at) < 5 {
            stoppedByAppAt = nil
            AppLog.shared.add("loopback", "local VPN: stopped by Poki itself; the retry stands")
            return
        }
        AppLog.shared.add("loopback", "local VPN: ended on purpose (turned off in Settings, or another VPN took over); not reconnecting")
        reconnect.ownerStopped()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
    }

    /// Why iOS stopped the tunnel, when it says: the log is how an owner (or an issue) tells a system
    /// stop from another VPN taking over.
    private func logStopReason() {
        manager?.connection.fetchLastDisconnectError { error in
            let reason = error.map { "\($0.localizedDescription) (\(($0 as NSError).domain) \(($0 as NSError).code))" } ?? "none reported"
            Task { @MainActor in AppLog.shared.add("loopback", "local VPN stopped, reason: \(reason)") }
        }
    }

    /// Dials again after `ReconnectPlan`'s next delay (jittered), if Poki is on and the owner has not
    /// ended the connection. The tries are counted when they fail, so a connect that works and drops
    /// again at once does not start over.
    private func scheduleReconnect(because cause: String) {
        guard wanted(), reconnectTask == nil else { return }
        guard let seconds = reconnect.lost() else {
            AppLog.shared.add("loopback", "local VPN: not reconnecting (\(cause)); " + (reconnect.stoppedByOwner ? "it was ended on purpose" : "the automatic tries are used up"))
            return
        }
        let wait = seconds * Double.random(in: 0.8...1.2)
        AppLog.shared.add("loopback", "local VPN: reconnecting in \(Int(wait.rounded())) s (\(cause))")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            // A change the owner started a moment ago finishes first.
            for _ in 0..<10 where self.busy { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled, self.wanted(), !self.busy else { return }
            // Poki's own tunnel stops first; what is left is somebody else's.
            for _ in 0..<10 where self.manager?.connection.status == .disconnecting { try? await Task.sleep(for: .milliseconds(500)) }
            if self.anotherVPNIsOn() {
                self.yieldToAnotherVPN()
                return
            }
            self.reconnecting = true
            do { try await self.bringUp() } catch { self.reconnecting = false }
        }
    }

    /// The interfaces iOS keeps scoped network settings for, one per active network or tunnel.
    private func anotherVPNIsOn() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
        return OtherVPN.isOn(interfaces: Array(scoped.keys))
    }

    /// The owner has a VPN on, and a second packet tunnel would take its place: stop dialling and say so.
    /// The owner's own tap on Enable Local Connection (or turning Poki on) is what starts it again.
    private func yieldToAnotherVPN() {
        reconnect.ownerStopped()
        reconnecting = false
        let message = "Another VPN appears to be on, so Poki did not turn its local connection back on. Turn that VPN off and tap Enable Local Connection, or choose an external connection in Setup."
        AppLog.shared.add("loopback", "local VPN: another VPN is on; not reconnecting")
        state = .failed(message)
        onAttention?(message)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "PokiLoopback", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
