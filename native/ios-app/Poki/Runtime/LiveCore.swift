import CryptoKit
import Foundation
import ImageIO
import PokiCore
import UniformTypeIdentifiers

/// PokiCore, linked: the on-phone MCP server behind the relay. This maps its events onto the shell's,
/// and answers its host questions (signing key, connector hashes, JPEG encoding, the runner's state).
final class LiveCore: CoreSession {
    private let host: AppCoreHost
    private let core: PokiCore
    let events: AsyncStream<ShellEvent>
    private let continuation: AsyncStream<ShellEvent>.Continuation
    private var pump: Task<Void, Never>?

    init(host: AppCoreHost, transport: HTTPTransport) {
        self.host = host
        var config = CoreConfig()
        config.userRoutineLearning = { UserDefaults.standard.bool(forKey: "poki.experimental.userRoutines") }
        // Signing tools may rename the app; its own id is Poki too.
        if let own = Bundle.main.bundleIdentifier { config.ownApps.append(own) }
        // Sensitive steps wait for the owner unless they turned asking off in Agents › Approvals; the
        // auto-classifier (Diagnostics › Testing) answers in their place when it is on.
        config.sensitive.enabled = Self.asksBeforeSensitiveSteps || ApprovalClassifier.isOn
        core = PokiCore(config: config, host: host, transport: transport)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        let continuation = self.continuation
        pump = Task { [core] in
            for await event in core.events { continuation.yield(Self.map(event)) }
        }
        core.onSession { signal in continuation.yield(.session(signal)) }
    }

    /// Agents › Approvals › Ask Before Sensitive Steps. Read when Poki starts.
    static let askKey = "approvals.ask"
    /// On unless the owner turned it off: a phone that never chose asks.
    static var asksBeforeSensitiveSteps: Bool { UserDefaults.standard.object(forKey: askKey) as? Bool ?? true }

    deinit { pump?.cancel() }

    func start(relay: RelayAddress) { core.start(relay: relay) }
    func stop() { core.stop(); continuation.yield(.relay(.off)) }
    func resolveApproval(id: String, approved: Bool) { core.resolveApproval(id: id, approved: approved) }
    /// The person finished a handed-off screen (Done on the Live Activity): PokiCore lets inputs through again.
    func handoffDone(id: String) { core.handoffDone(id: id) }
    func clearTap(on text: String, inApp bundleID: String?, named name: String?, waiting seconds: Double) async -> TapClearance {
        await core.clearTap(on: text, inApp: bundleID, named: name, waiting: seconds)
    }
    func accessChanged() { core.accessChanged() }
    /// The app's own MCP tools (ask_poki), after look, do and status.
    func setHostTools(_ tools: [HostTool]) { core.setHostTools(tools) }
    func tool(_ name: String, arguments: String) async -> ToolResult { await core.tool(name, arguments: arguments) }
    /// `look`, `do` or `status` for the chat's model loop inside the app.
    func callTool(_ name: String, arguments: String) async -> PokiCore.ToolAnswer { await core.callTool(name, arguments: arguments) }
    /// Ends the task: the phone goes back to the app it began in (or, `switching: false`, stays). The
    /// line says what happened.
    func finishTask(switching: Bool = true) async -> String? { await core.finishTask(switching: switching) }

    private static func map(_ event: CoreEvent) -> ShellEvent {
        switch event {
        case .relay(.connecting): return .relay(.connecting)
        case .relay(.ready): return .relay(.ready)
        case .relay(.offline(let why)): return .relay(.offline(why))
        case .toolStarted(let activity): return .toolStarted(name: activity.name, summary: activity.summary, session: activity.session)
        case .toolFinished(let activity, let outcome, let facts):
            let delivery: String
            switch outcome { case .done(let text): delivery = text; case .failed(let text): delivery = "failed: \(text)" }
            return .toolFinished(summary: activity.summary, delivery: delivery, app: facts.app, thumbnail: facts.thumbnail, error: facts.error, session: activity.session)
        case .approvalRequested(let approval):
            return .approvalRequested(PendingApproval(id: approval.id, app: approval.app, summary: approval.summary, reason: approval.reason, expires: approval.expires))
        case .approvalEnded(let id, let approved): return .approvalEnded(id: id, approved: approved)
        case .handoffRequested(let id, let kind, let text, let app): return .handoffRequested(id: id, kind: kind, text: text, app: app)
        case .handoffEnded(let id, let how): return .handoffEnded(id: id, how: how)
        }
    }
}

/// The relay key PokiCore signs with: the app's Ed25519 key from the keychain.
struct DeviceKey: RelayKey {
    let key: Curve25519.Signing.PrivateKey
    var publicKey: Data { key.publicKey.rawRepresentation }
    func sign(_ message: Data) throws -> Data { try key.signature(for: message) }
}

/// PokiCore's host. PokiCore holds it weakly, so AppModel keeps it. Thread-safe: PokiCore calls it from
/// its own tasks.
final class AppCoreHost: CoreHost, @unchecked Sendable {
    private let lock = NSLock()
    private var key: Curve25519.Signing.PrivateKey?
    private var hashes: [String] = []
    private var runner: RunnerState = .starting("not started")
    private var restart: (@Sendable () -> Void)?
    private var paused = false
    private var wake: (@Sendable () -> Void)?
    private var warm: (@Sendable () -> Void)?
    private var retry: (@Sendable () -> Void)?

    func update(key: Curve25519.Signing.PrivateKey?, hashes: [String]) { lock.withLock { self.key = key; self.hashes = hashes } }
    func update(runner: RunnerState) { lock.withLock { self.runner = runner } }
    /// The state as last given, without the wake side effect of `runnerState()` (tests).
    var currentRunner: RunnerState { lock.withLock { runner } }
    func onRestart(_ action: @escaping @Sendable () -> Void) { lock.withLock { restart = action } }
    func onWake(_ action: @escaping @Sendable () -> Void) { lock.withLock { wake = action } }
    func onWarmUp(_ action: @escaping @Sendable () -> Void) { lock.withLock { warm = action } }
    /// A tool call found automation failed or not open yet: the app may try again (the in-process session, ESP-152).
    func onRetry(_ action: @escaping @Sendable () -> Void) { lock.withLock { retry = action } }
    /// MCP initialize: a paused runner starts now, and the app gets the session ready.
    func warmUp() {
        _ = runnerState()
        lock.withLock { warm }?()
    }
    /// The runner was stopped while idle (or by the owner): the next tool call starts it again.
    func setPaused(_ value: Bool) { lock.withLock { paused = value } }

    func signingKey() throws -> RelayKey {
        guard let key = lock.withLock({ self.key }) else { throw NSError(domain: "Poki", code: 1, userInfo: [NSLocalizedDescriptionKey: "no relay key in the keychain"]) }
        return DeviceKey(key: key)
    }
    func accessHashes() -> [String] { lock.withLock { hashes } }
    private var consent: (@Sendable (String, String, String) async -> Bool)?
    /// The owner's OK for a client outside the relay's known list (AppModel.askToConnect).
    func onConsent(_ action: @escaping @Sendable (String, String, String) async -> Bool) { lock.withLock { consent = action } }
    func approveConnection(client: String, callback: String, connector: String) async -> Bool {
        guard let ask = lock.withLock({ consent }) else { return false }
        return await ask(client, callback, connector)
    }
    /// PokiCore asks before every device tool. A paused runner is started here, so the call answers
    /// "starting" and the next one finds it running. A failed one is answered as it is, and the app
    /// is asked to try again for the next call.
    func runnerState() -> RunnerState {
        let (state, then) = lock.withLock { () -> (RunnerState, (@Sendable () -> Void)?) in
            guard paused else {
                // Failed, or still starting: the app is asked to (re)open its session. Opening is
                // idempotent and the app ignores the ask while an open is under way, so a call that
                // waits on "starting" can never wait on an open nobody started.
                if case .failed = runner { return (runner, retry) }
                if case .starting = runner { return (runner, retry) }
                return (runner, nil)
            }
            paused = false
            runner = .starting("starting again after being idle; it takes a few seconds")
            return (runner, self.wake)
        }
        then?()
        return state
    }
    func restartRunner() {
        let (wasPaused, wake, restart) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?, (@Sendable () -> Void)?) in
            let was = paused; paused = false
            return (was, self.wake, self.restart)
        }
        if wasPaused { wake?() } else { restart?() }
    }

    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Self.maxSide(source, width: width)] as CFDictionary) else {
            throw NSError(domain: "Poki", code: 2, userInfo: [NSLocalizedDescriptionKey: "the screenshot is not an image"])
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw NSError(domain: "Poki", code: 3) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Poki", code: 4) }
        return out as Data
    }

    /// The thumbnail size limit is the longer side; a portrait screenshot `width` wide has a longer
    /// height, so the limit is the height that width gives.
    private static func maxSide(_ source: CGImageSource, width: Int) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0 else { return width }
        return Int((Double(width) * max(w, h) / w).rounded())
    }
}

extension RunnerStatus {
    /// The launcher's state as PokiCore's RunnerState.
    var coreState: RunnerState {
        switch state {
        case "running": return .running
        case "failed": return .failed(detail ?? "the runner stopped", fix: fix)
        default: return .starting(title)
        }
    }
}
