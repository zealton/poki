import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How a request to the runner ended, as far as the phone is concerned.
public enum Delivery: String, Sendable {
    case sent
    /// Refused before anything reached the phone.
    case notSent = "not_sent"
    /// It may or may not have reached the phone.
    case unknown
}

public struct RunnerError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var delivery: Delivery
    public var status: Int? = nil
    /// WebDriver's error code when the runner answered with one ("unknown command", "invalid session id").
    public var code: String? = nil
    /// No answer at all (refused or timed out), as opposed to an answer that says no.
    public var silent = false
    /// A tree read that failed: the app the runner says is in front all the same.
    public var foreground: Foreground? = nil
    public var description: String { message }
}

/// One HTTP exchange. URLSession on the phone; a fake in tests.
public protocol HTTPTransport: Sendable {
    var verifiesNativeTyping: Bool { get }
    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data)
}

public extension HTTPTransport {
    var verifiesNativeTyping: Bool { false }
}

public enum TransportError: Error, Sendable {
    /// Nothing listens there (the runner is down).
    case refused
    case timedOut
    case other(String)
}

public final class URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }
    public func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        // One connection per request. The runner drops a kept-alive connection when it fails to write
        // an answer to it (a request we gave up on), and a request sent on that connection in the same
        // moment is lost with "the network connection was lost" after no time at all.
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost: throw TransportError.refused
            case .timedOut: throw TransportError.timedOut
            default: throw TransportError.other(error.localizedDescription)
            }
        }
    }
}

/// The WebDriverAgent runner on the phone (W3C WebDriver plus WDA's extensions). Every request has its
/// own timeout, and one session is kept and made again when WDA says it is gone.
/// How much of the tree WDA snapshots: `depth` (WDA default 50) bounds nesting, `children` bounds
/// the children of one element (a feed with hundreds of sibling cells is cut, not nesting). After a
/// read that timed out the next read asks for less; a fast read asks for more again.
struct SnapshotLimits: Equatable, Sendable {
    var depth: Int
    var children: Int
    static let full = SnapshotLimits(depth: 50, children: 2_147_483_647)
    static let fewestChildren = 60
    var isFull: Bool { self == .full }
    /// The next step down: the children first (siblings are what a dense screen has), then the depth.
    var smaller: SnapshotLimits {
        if children > 150 { return SnapshotLimits(depth: depth, children: 150) }
        if depth > 12 { return SnapshotLimits(depth: max(12, depth / 2), children: max(Self.fewestChildren, children / 2)) }
        return SnapshotLimits(depth: depth, children: max(Self.fewestChildren, children / 2))
    }
    /// The next step back up.
    var larger: SnapshotLimits {
        let d = min(50, depth * 2)
        let c = children >= 600 ? Self.full.children : children * 2
        return SnapshotLimits(depth: d, children: c)
    }
    var described: String {
        var parts: [String] = []
        if depth < 50 { parts.append("depth \(depth)") }
        if children != Self.full.children { parts.append("at most \(children) children per element") }
        return parts.joined(separator: ", ")
    }
    var caveat: String {
        var parts: [String] = []
        if depth < 50 { parts.append("deeper parts of nested elements may be missing") }
        if children != Self.full.children { parts.append("only the first \(children) children of each element are listed (the end of a long list, and anything an app put after it, is not; scroll_to finds what is further down)") }
        return parts.joined(separator: "; ")
    }
}

public final class Runner: @unchecked Sendable {
    public let url: URL
    let transport: HTTPTransport
    var verifiesNativeTyping: Bool { transport.verifiesNativeTyping }
    private let state = LockedBox<(session: String?, misses: Int)>((nil, 0))
    /// Called after `unhealthyAfter` silent requests in a row: at once when the runner refused or
    /// broke the connection, and only after a `GET /status` probe also went unanswered for
    /// `probeTimeout` when the requests merely timed out. WDA serves every request on its main
    /// thread, so one slow read (a big tree, a keyboard coming up) holds back all the others; that
    /// runner is busy, not gone, and restarting it would cost the owner far more than waiting.
    var onUnhealthy: (@Sendable () -> Void)?
    var unhealthyAfter = 2
    var probeTimeout: Double = 15
    private let probing = LockedBox(false)
    /// The request this side gave up on while the runner was still serving it, until a later request
    /// on the runner's queue is answered. WDA serves every request but a few (status, screenshot,
    /// ending a session) one after another on its main thread, so until that one is done the runner
    /// is busy, whatever is sent to it.
    private let stall = LockedBox<(path: String, since: Double)?>(nil)
    /// How many actions this side has given up on (sent, and not answered in time). A call compares
    /// it before and after an action to tell a timeout that reached the runner from one that did not.
    let actionsGivenUp = LockedBox(0)
    /// What the runner is still finishing, if anything: "GET /source from 7 s ago (restarted on its
    /// own if it is not through in 15 s)".
    public var busyWith: String? { stall.value.map { "\($0.path) from \(Int((now() - $0.since).rounded())) s ago (the runner is restarted on its own if it is not through in \(Int(wedgedAfter)) s)" } }
    /// A queued request this side gave up on that is still unanswered after this long, while a cheap
    /// queued probe is not answered either, is a wedged runner (seen in the gym: an app whose main
    /// loop hung held WDA's queue for over a minute, and every read, action and screenshot behind it;
    /// WDA's own status answered, so the health probe saw nothing wrong). Nothing sent to it would
    /// run, so it is restarted (`onUnhealthy`), and the next call says why.
    var wedgedAfter: Double = 15
    /// Why the runner was last restarted by this side, for the next call to report (once).
    let lastRestart = LockedBox<String?>(nil)
    /// The host's own way to a screenshot (apart from the runner), used when the runner gives none.
    var screenshotFallback: (@Sendable () async -> Data?)?
    /// Requests WDA answers apart from its queue (FBRoute `.standalone`).
    static let standalone: Set<String> = ["GET /status", "GET /screenshot", "DELETE /session"]

    public init(url: URL, transport: HTTPTransport = URLSessionTransport()) {
        self.url = url
        self.transport = transport
    }

    public var consecutiveMisses: Int { state.value.misses }
    public var hasSession: Bool { state.value.session != nil }

    /// Settings for every session. WDA waits after each gesture until the app has been still for up
    /// to `animationCoolOffTimeout` (2 s) and before each event until it is idle for up to
    /// `waitForIdleTimeout` (10 s); an app that never stops animating (a feed with videos) used all of
    /// both on every drag. Poki pauses briefly itself and the model reads the screen after.
    ///
    /// `accessibilityDeadline` (WDA #1210, off by default): before reading an app's tree WDA checks
    /// that the app's event loop answers within this time, and fails the read if not. Without it a
    /// read of an app that never goes idle (a looping animation over the keyboard on the simulator)
    /// blocks WDA's main thread, and with it every request behind it, screenshots and Home included,
    /// for half a minute.
    /// WDA decides which app is "active" by the app that owns one screen point, by default 20 % in
    /// from the top left, where a notification banner lies (seen on the phone: a Bedtime banner made
    /// a read answer SpringBoard's tree with no app). The centre of the screen belongs to the app,
    /// and to a system alert (a paste or permission prompt) when one is up, so the tree shows it.
    /// `snapshotMaxDepth` (WDA default 50) bounds the tree; after a read that timed out the next
    /// read asks for half the depth (never under 12), and a fast read restores it.
    static func sessionSettings(deadline: Double, limits: SnapshotLimits) -> JSON {
        ["animationCoolOffTimeout": 0, "waitForIdleTimeout": 0.5, "accessibilityDeadline": .number(deadline), "activeAppDetectionPoint": "200,420", "snapshotMaxDepth": .number(Double(limits.depth)), "snapshotMaxChildren": .number(Double(limits.children))]
    }
    /// WDA's settings live in its process (FBConfiguration), not in the session: set once per runner
    /// life, by the first session, and again only to change the depth.
    public var accessibilityDeadline: Double = 2
    let limits = LockedBox(SnapshotLimits.full)
    let nextLimits = LockedBox(SnapshotLimits.full)
    let settingsApplied = LockedBox(false)

    /// The snapshot limits for the next read, applied through the session's settings when they differ
    /// from what the runner has (a queued request, bounded at 2 s). Without a session they are noted
    /// for the open to apply (every open sends the settings): a read never waits on a session open
    /// for them (the soak: an open that hung held a look 3 s past its read, up to the backstop).
    func useLimits(_ wanted: SnapshotLimits) async {
        guard wanted != limits.value else { return }
        guard hasSession else { limits.value = wanted; return }  // the open sends them
        guard busyWith == nil, let id = try? await session(timeout: 2) else { return }  // a busy runner keeps what it has
        if (try? await raw("POST", "/session/\(id)/appium/settings", ["settings": ["snapshotMaxDepth": .number(Double(wanted.depth)), "snapshotMaxChildren": .number(Double(wanted.children))]], timeout: 2, countsAsMiss: false)) != nil {
            limits.value = wanted
        }
    }

    /// The runner's settings are in place (a session was opened in this runner's life).
    func ensureSettings(timeout: Double) async {
        guard !settingsApplied.value else { return }
        _ = try? await session(timeout: timeout)
    }

    /// One request outside the session. `countsAsMiss: false` for a request that may rightly take long
    /// (a gesture): its timeout is not taken as a sign that the runner is gone.
    public func raw(_ method: String, _ path: String, _ body: JSON? = nil, timeout: Double = 4, countsAsMiss: Bool = true) async throws -> JSON {
        let target = URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!
        let queued = !Self.standalone.contains("\(method) \(Self.short(path))")
        let busyBefore = queued ? busyWith : nil
        func busyNote() -> String { busyBefore.map { "; the runner is still finishing an earlier \($0)" } ?? "" }
        let result: (status: Int, body: Data)
        do {
            result = try await withDeadline(timeout + 0.5, "the runner's answer to \(method) \(Self.short(path))") { [transport] in
                try await transport.send(method: method, url: target, body: body?.data(), timeout: timeout)
            }
        } catch TransportError.refused {
            // A refused connection is a runner process that is gone: what it was finishing went with it.
            stall.value = nil
            miss()
            throw RunnerError(message: "the runner is not running (connection refused at \(url.absoluteString)); it is being restarted: call look again in about 10 s", delivery: .notSent, silent: true)
        } catch let error as DeadlineExceeded {
            if countsAsMiss { miss(timedOut: true) }
            if queued { abandon(method, path, endSession: method != "GET") }
            throw RunnerError(message: error.description + busyNote(), delivery: .unknown, silent: true)
        } catch TransportError.timedOut {
            if countsAsMiss { miss(timedOut: true) }
            if queued { abandon(method, path, endSession: method != "GET") }
            throw RunnerError(message: "the runner did not answer \(method) \(Self.short(path)) within \(DeadlineExceeded.format(timeout))" + busyNote(), delivery: .unknown, silent: true)
        } catch is CancellationError {
            // The call's own time ran out around this request (an action's cap): this side gave up on
            // it just as on a timeout, so what is queued behind it must not run late.
            if queued { abandon(method, path, endSession: method != "GET") }
            throw CancellationError()
        } catch {
            miss()
            throw RunnerError(message: "the runner did not answer \(method) \(Self.short(path)): \(error)", delivery: .unknown, silent: true)
        }
        state.update { $0.misses = 0 }
        if queued { stall.value = nil }
        let parsed = (try? JSON.parse(result.body)) ?? (result.body.isEmpty ? .object([:]) : ["value": .string(String(decoding: result.body, as: UTF8.self))])
        let value = parsed["value"] ?? parsed
        if let code = value["error"]?.string {
            let message = (value["message"]?.string ?? code).split(separator: "\n").first.map(String.init) ?? code
            throw RunnerError(message: "the runner refused \(method) \(Self.short(path)): \(message)", delivery: code == "poki user takeover" ? .unknown : .notSent, status: result.status, code: code)
        }
        if !(200..<300).contains(result.status) {
            throw RunnerError(message: "the runner answered HTTP \(result.status) to \(method) \(Self.short(path))", delivery: .notSent, status: result.status)
        }
        return value
    }

    /// This side gave up on a queued request. The runner still serves it, and everything sent after
    /// it waits its turn behind it, so the next action would run late, after the model had moved on
    /// (seen on the phone: a feed's tree took longer than a read, and the swipes and taps sent after
    /// it landed well after the agent had reported them failed). So the session is ended at once
    /// (`DELETE /session`, answered apart from the queue): WDA answers every request still queued for
    /// it with "session does not exist" and does not run them, and the request it is serving is the
    /// last thing it does for that session. The next call opens a new session, which waits its turn
    /// behind that request and is answered as busy when its turn does not come in time.
    /// A read (GET) that times out keeps the session: nothing queued behind it can act, and ending
    /// the session would only put the next session open behind the same slow read (seen on the
    /// phone: every look in WeChat opened a session that queued behind the read before it). An
    /// action or a session open that times out ends the session, so nothing runs late.
    private func abandon(_ method: String, _ path: String, endSession: Bool = true) {
        let stalled: (path: String, since: Double) = ("\(method) \(Self.short(path))", now())
        if stall.update({ s -> Bool in if s == nil { s = stalled; return true }; return false }) { watch(stalled) }
        guard endSession, let id = state.value.session, path.hasPrefix("/session/\(id)") else { return }
        actionsGivenUp.update { $0 += 1 }
        forgetSession()
        Task { [transport, url] in
            _ = try? await withDeadline(2.5, "ending the session") {
                try await transport.send(method: "DELETE", url: URL(string: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/session/\(id)")!, body: nil, timeout: 2)
            }
        }
    }

    /// The watchdog for one stall: after `wedgedAfter`, when the same request is still unanswered, a
    /// cheap queued probe (3 s) tells whether the queue moves at all; when it does not, the runner is
    /// wedged and restarted. A runner that is through by then has cleared the stall on its own.
    private func watch(_ stalled: (path: String, since: Double)) {
        Task { [weak self] in
            guard let wedgedAfter = self?.wedgedAfter else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, wedgedAfter) * 1_000_000_000))
            guard let self, let s = self.stall.value, s.since == stalled.since else { return }
            if (try? await self.raw("GET", "/wda/activeAppInfo", timeout: 3, countsAsMiss: false)) != nil { return }
            guard let still = self.stall.value, still.since == stalled.since else { return }
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            self.lastRestart.value = "the runner wedged on \(still.path) (unanswered for \(Int((now() - still.since).rounded())) s), so it was restarted at \(f.string(from: Date()))"
            self.forgetRunner()
            self.onUnhealthy?()
        }
    }

    private func miss(timedOut: Bool = false) {
        let misses = state.update { s -> Int in s.misses += 1; return s.misses }
        guard misses == unhealthyAfter else { return }
        if !timedOut { onUnhealthy?(); return }
        // Slow, not refused: ask whether it is still there before giving up on it. One probe at a time;
        // it runs apart from the calls, which have already answered with what they had.
        guard probing.update({ p -> Bool in defer { p = true }; return !p }) else { return }
        Task { [weak self, transport, url, probeTimeout] in
            let alive = (try? await withDeadline(probeTimeout + 0.5, "the runner's status") {
                try await transport.send(method: "GET", url: url.appendingPathComponent("status"), body: nil, timeout: probeTimeout)
            }).map { (200..<300).contains($0.status) } ?? false
            guard let self else { return }
            self.probing.value = false
            if alive { self.state.update { $0.misses = 0 } } else { self.onUnhealthy?() }
        }
    }

    func forgetSession() { state.update { $0.session = nil } }
    /// The runner was restarted: its settings are the defaults again.
    func forgetRunner() { forgetSession(); settingsApplied.value = false; limits.value = .full; stall.value = nil }

    /// Whether the runner is through with the request this side gave up on: a cheap queued request
    /// (opening the session, or the active app) answered within `timeout` means the queue has
    /// drained past it. Nothing is sent to a runner that is still busy.
    func waitUntilFree(timeout: Double) async -> Bool {
        guard busyWith != nil else { return true }
        let t = max(0.3, timeout)
        if hasSession {
            _ = try? await call("GET", "/wda/activeAppInfo", timeout: t, countsAsMiss: false)
        } else {
            _ = try? await session(timeout: t)
        }
        return busyWith == nil
    }

    private let opening = LockedBox<Task<String, Error>?>(nil)

    /// The session, opened once when there is none. Concurrent callers share one open, and each waits
    /// at most its own `timeout` (and 8 s): a slow open never holds a call past its deadline, and the
    /// open goes on for the next caller.
    func session(timeout: Double = 8) async throws -> String {
        if let id = state.value.session { return id }
        let task = opening.update { current -> Task<String, Error> in
            if let current { return current }
            let made = Task { [self] () throws -> String in
                defer { opening.value = nil }
                let value = try await raw("POST", "/session", ["capabilities": ["alwaysMatch": .object([:])]], timeout: 8)
                guard let id = value["sessionId"]?.string ?? value["capabilities"]?["sessionId"]?.string else {
                    throw RunnerError(message: "the runner opened no session", delivery: .notSent)
                }
                // Best effort: a runner that refuses the settings still works, only slower.
                if (try? await raw("POST", "/session/\(id)/appium/settings", ["settings": Self.sessionSettings(deadline: accessibilityDeadline, limits: limits.value)], timeout: 2, countsAsMiss: false)) != nil {
                    settingsApplied.value = true
                }
                state.update { $0.session = id }
                return id
            }
            current = made
            return made
        }
        do {
            return try await withDeadline(max(0.2, min(8, timeout)), "opening a session with the runner") { try await task.value }
        } catch let error as DeadlineExceeded {
            throw RunnerError(message: error.description + (busyWith.map { "; the runner is still finishing an earlier \($0)" } ?? ""), delivery: .notSent, silent: true)
        }
    }

    /// A request inside the session, made again once on a new session when WDA no longer knows it.
    public func call(_ method: String, _ path: String, _ body: JSON? = nil, timeout: Double = 4, countsAsMiss: Bool = true) async throws -> JSON {
        let id = try await session(timeout: timeout)
        do {
            return try await raw(method, "/session/\(id)\(path)", body, timeout: timeout, countsAsMiss: countsAsMiss)
        } catch let error as RunnerError where error.code == "invalid session id" || error.message.lowercased().contains("invalid session id") || (error.status == 404 && error.code == nil) {
            state.update { if $0.session == id { $0.session = nil } }
            return try await raw(method, "/session/\(try await session(timeout: timeout))\(path)", body, timeout: timeout, countsAsMiss: countsAsMiss)
        }
    }

    static func short(_ path: String) -> String {
        let trimmed = path.replacingOccurrences(of: #"/session/[^/]+"#, with: "", options: .regularExpression)
        return trimmed.split(separator: "?").first.map(String.init) ?? trimmed
    }
}
