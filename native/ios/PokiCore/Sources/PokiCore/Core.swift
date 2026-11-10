import Foundation

public struct CoreConfig: Sendable {
    public var runnerURL: URL
    public var sensitive: SensitivityRules
    /// How long `do` holds for an approval before answering approval_required. Owners took 42 to 47 s
    /// to approve on the phone, so this is as long as a request lives (`Approvals.lifetime`, 120 s)
    /// less a margin; a relay that gives up sooner shortens it for the call (`RelayRequest.answerBy`).
    public var approvalWait: Double
    /// The hard cap for one tool call, everything included.
    public var toolDeadline: Double
    /// The device time one `do` may spend on its actions.
    public var actionCap: Double
    /// The cap for one screen read (tree and screenshot together).
    public var readTimeout: Double
    /// How long a second tool call waits for the first before answering busy.
    public var busyWait: Double
    /// How long a call waits for a runner that is starting (the app wakes it when a call comes in).
    public var runnerWait: Double
    /// The form the element tree is asked for: "xml" (the default) or "json". WDA's JSON tree fetches
    /// each element's custom actions from the accessibility server, one round trip per element,
    /// whatever is excluded; its XML tree leaves them out unless asked. On the CI simulator the XML
    /// read of Settings took 0.2 to 0.4 s against 0.6 to 0.7 s, and 0.3 s against 2.0 s with the
    /// keyboard up.
    public var treeFormat: String
    /// WDA's `accessibilityDeadline`: how long the app's main loop may take to answer before a tree
    /// read is refused (0 turns the check off). 2 s on the phone; the gym compares both.
    public var accessibilityDeadline: Double
    /// Poki's own bundle ids (and the ids under them, like a development build's). The approval card is
    /// in Poki, so `do` and a voice tap refuse to tap there when they can tell Poki is in front. A tap
    /// that lands on its Live Activity (the Dynamic Island) brings Poki to the front; `do` brings the app
    /// it was working in back and says so, rather than act inside Poki.
    public var ownApps: [String]
    /// How long without a look or do ends a task that was never finished, so the next call starts
    /// a new one. Well beyond an agent's thinking; the app's idle stop usually ends the task first.
    public var taskGap: Double
    /// Whether touches and typing are shaped after a person's (`Humanize`): varied press times, a
    /// point or two of scatter inside the element, minimum-jerk drags, typing in bursts. nil reads
    /// `POKI_HUMANIZE` (on unless off); false sends the exact legacy schedules.
    public var humanize: Bool?
    /// The agent's memory (routines and notes); nil uses `RoutineStore.shared`, the app's file.
    public var memory: RoutineStore?
    public var userRoutineLearning: @Sendable () -> Bool = { false }

    public init(runnerURL: URL = URL(string: "http://127.0.0.1:8100")!, sensitive: SensitivityRules = SensitivityRules(), approvalWait: Double = 115, toolDeadline: Double = 25, actionCap: Double = 6, readTimeout: Double = 4, busyWait: Double = 2, runnerWait: Double = 15, treeFormat: String = "xml", ownApps: [String] = ["nz.zheha.poki"], accessibilityDeadline: Double = 2, taskGap: Double = 300, humanize: Bool? = nil) {
        self.accessibilityDeadline = accessibilityDeadline
        self.humanize = humanize
        self.runnerURL = runnerURL
        self.sensitive = sensitive
        self.approvalWait = approvalWait
        self.toolDeadline = toolDeadline
        self.actionCap = actionCap
        self.readTimeout = readTimeout
        self.busyWait = busyWait
        self.runnerWait = runnerWait
        self.treeFormat = treeFormat
        self.ownApps = ownApps
        self.taskGap = taskGap
    }

    /// Whether `app` is Poki itself: one of `ownApps`, or its Live Activity widget or tunnel
    /// extension. Not every app under Poki's id prefix: the gym (nz.zheha.poki.gym) is an app
    /// under test, and a prefix rule refused every tap in it. An app known only by name counts
    /// when it is named Poki.
    func isPoki(_ app: Foreground?) -> Bool {
        guard let app else { return false }
        guard let bundle = app.bundleID, !bundle.isEmpty else { return app.name?.caseInsensitiveCompare("Poki") == .orderedSame }
        return ownApps.contains { bundle == $0 || bundle == $0 + ".widgets" || bundle == $0 + ".tunnel" }
    }

    /// What `do` and a voice tap answer when the tap would land in Poki.
    static let ownAppRefusal = "only the phone's owner can approve, by tapping it on the phone themselves; Poki takes no taps or typing inside the Poki app"
}

/// The launcher's view of the runner, as the app shell reports it (from PokiLauncher's events).
public enum RunnerState: Sendable, Equatable {
    case running
    case starting(String)
    case failed(String, fix: String?)

    public var isRunning: Bool { self == .running }
    public var describe: String {
        switch self {
        case .running: return "running"
        case .starting(let detail): return "starting (\(detail))"
        case .failed(let detail, let fix): return "failed: \(detail)" + (fix.map { ". Fix on the phone: \($0)" } ?? "")
        }
    }
}

/// How the phone reaches its own developer services at 10.7.0.1.
public enum LocalConnection: Sendable, Equatable {
    /// Poki's own packet tunnel, in the local-VPN build. It does not reconnect by itself.
    case builtIn
    /// The owner's proxy app (or a loopback app) reflects 10.7.0.1.
    case external
}

extension RunnerState {
    /// The runner is waiting for the loopback: what the agent reads, with when it stopped answering
    /// (`since`, a clock time) and how the owner brings it back on this connection. `tunnelWithoutAnswer`:
    /// a 10.7.0.x interface is up, but nothing answers through it.
    public static func waitingForLoopback(since: String?, tunnelWithoutAnswer: Bool, connection: LocalConnection) -> RunnerState {
        let since = since.map { " since \($0)" } ?? ""
        let why: String, fix: String
        switch connection {
        case .builtIn:
            why = tunnelWithoutAnswer ? "Poki's local connection is on, but this iPhone's developer services do not answer at 10.7.0.1" : "Poki's local connection is off, or another VPN app replaced it"
            fix = "The owner opens Poki and taps Enable local connection in Setup, or turns Poki's VPN back on in iOS Settings > VPN"
        case .external:
            why = tunnelWithoutAnswer ? "the proxy app's tunnel is on but does not reflect 10.7.0.1" : "the loopback at 10.7.0.1 is not answering"
            fix = "The owner turns the proxy app's tunnel (Surge, Loon, Shadowrocket or sing-box) back on"
        }
        return .starting("waiting for the loopback\(since): \(why). \(fix); the runner starts again by itself within seconds of that. Nothing on the phone changes meanwhile")
    }
}

/// The relay's signing key: Ed25519, kept in the keychain on the phone.
public protocol RelayKey: Sendable {
    /// The raw 32-byte public key.
    var publicKey: Data { get }
    func sign(_ message: Data) throws -> Data
}

public protocol CoreHost: AnyObject, Sendable {
    func signingKey() throws -> RelayKey
    /// sha256 (hex) of each connector secret.
    func accessHashes() -> [String]
    /// A JPEG of the PNG screenshot, `width` pixels wide.
    func jpeg(fromPNG png: Data, width: Int, quality: Double) throws -> Data
    func runnerState() -> RunnerState
    func restartRunner()
    /// An agent connected (MCP initialize): get ready for its first look now, not during it.
    func warmUp()
    /// Text read from a PNG screenshot, used for elements an app collapsed. PokiCore answers it with
    /// Vision by default, so a host need not implement it.
    func recognizeText(inPNG png: Data) async -> [RecognizedText]?
    /// A screenshot (PNG, one pixel per screen point is not required) that does not go through the
    /// runner: the launcher's own path to the device (the DVT screenshot service over its tunnel, or
    /// simctl on the simulator). Asked for only when the runner gives none (wedged, or restarting),
    /// so a hung app never blinds the model. Nil (the default) means there is no such path.
    func screenshotWithoutRunner() async -> Data?
    /// The relay asks whether a client outside its known list may sign in through a connector: its
    /// registered name, the host its sign-in returns to, and the connector's secret hash. Only the
    /// owner answers (on the phone). The default says no.
    func approveConnection(client: String, callback: String, connector: String) async -> Bool
}

extension CoreHost {
    public func screenshotWithoutRunner() async -> Data? { nil }
    public func approveConnection(client: String, callback: String, connector: String) async -> Bool { false }
}

public enum RelayState: Sendable, Equatable {
    case connecting
    case ready(url: String)
    case offline(String)
}

public struct ToolActivity: Sendable, Equatable {
    public var id: String
    public var name: String
    public var summary: String
    public var started: Date
    /// The MCP session that made the call (its `mcp-session-id`), nil for a caller inside the app.
    public var session: String? = nil
}

/// An MCP client's session: begun by `initialize`, ended by its DELETE (or never, when the client just
/// goes away). The app lists them next to its own chats.
public enum SessionSignal: Sendable, Equatable {
    /// `client` and `version` are the client's own `clientInfo` from initialize.
    /// `connector` is the sha256 of the connector secret the session came through, when the relay says.
    case started(id: String, client: String, version: String?, connector: String? = nil)
    case ended(id: String)
}

/// A tool the app adds to the MCP catalog (`ask_poki`, the in-app agent). It is listed after the core's
/// own tools and runs in `call()` outside the one-call-at-a-time gate, since it makes its own look and do
/// calls. `schemaJSON` is the inputSchema as a JSON object. A name the core already uses (look, do,
/// routines, status) is not taken.
///
/// `timeLeft` is how many seconds the caller still waits for the answer (the relay's deadline less a
/// margin), nil when nobody said; a tool that may take longer answers before then and lets the caller
/// come back for the result. The catalog says `listChanged: false`: a client that read tools/list before
/// the app added its tools sees them only after it initializes again.
public struct HostTool: Sendable {
    public var name: String
    public var description: String
    public var schemaJSON: String
    public var run: @Sendable (_ arguments: String, _ session: String?, _ timeLeft: Double?) async -> PokiCore.ToolAnswer
    public init(name: String, description: String, schemaJSON: String, run: @escaping @Sendable (_ arguments: String, _ session: String?, _ timeLeft: Double?) async -> PokiCore.ToolAnswer) {
        self.name = name; self.description = description; self.schemaJSON = schemaJSON; self.run = run
    }
}

public enum ToolOutcome: Sendable, Equatable {
    case done(String)
    case failed(String)
}

/// What the Live Activity shows after a call: the app in front and a small JPEG of the screen
/// (about 96 pixels wide, a few kB; store it in the app group, since ActivityKit's state is 4 kB).
public struct ToolFacts: Sendable, Equatable {
    public var app: String?
    public var thumbnail: Data?
    /// The answer's `error:` line when the call failed, with the text it typed taken out. For the log.
    public var error: String? = nil
}

public enum CoreEvent: Sendable, Equatable {
    case relay(RelayState)
    case toolStarted(ToolActivity)
    case toolFinished(ToolActivity, ToolOutcome, ToolFacts)
    case approvalRequested(Approval)
    case approvalEnded(id: String, approved: Bool?)
    /// The model handed a step to the owner (`{handoff: {kind, text}}`: a passcode, a password, a
    /// verification, a payment it will not make). `kind` is one of passcode, password, verification,
    /// payment, other (the app adds runnerPasscode itself). The Live Activity shows it with a Done
    /// button; no input is sent until `handoffDone(id:)` (Done) or the model takes it back
    /// (`{handoff: false}`), while every look is served and the model keeps polling.
    case handoffRequested(id: String, kind: String, text: String?, app: String?)
    /// `how` is "done" (the owner tapped Done) or "takenBack" (the model sent `{handoff: false}`).
    case handoffEnded(id: String, how: String)
}

/// A step handed to the owner by the model, shown in the Live Activity until the owner taps Done
/// or the model takes it back.
public struct Handoff: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var text: String
    public var requested: Date
    public var done: Date?
    /// A user takeover cannot be dismissed by an agent action.
    public var ownerOnly: Bool
    public init(id: String, kind: String, text: String, requested: Date, done: Date? = nil, ownerOnly: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.requested = requested
        self.done = done
        self.ownerOnly = ownerOnly
    }
}

public struct RelayRequest: Sendable {
    public var id: String
    public var method: String
    public var headers: [String: String]
    public var body: String
    /// When the relay stops waiting for this request and answers the caller itself (`now()`, monotonic
    /// seconds): its `req_timeout_ms` after the request arrived. nil for a call that does not come
    /// through a relay, or from a relay that did not say.
    public var answerBy: Double?
    public init(id: String, method: String, headers: [String: String], body: String, answerBy: Double? = nil) {
        self.id = id
        self.method = method
        self.headers = headers
        self.body = body
        self.answerBy = answerBy
    }
}

public struct RelayResponse: Sendable, Equatable {
    public var id: String
    public var status: Int
    public var headers: [String: String]
    public var body: String
}

/// Poki on the phone: the MCP server behind the relay.
public final class PokiCore: @unchecked Sendable {
    public let config: CoreConfig
    weak var host: CoreHost?
    let runner: Runner
    let computer: Computer
    let approvals: Approvals
    private let continuation: AsyncStream<CoreEvent>.Continuation
    public let events: AsyncStream<CoreEvent>
    private let gate = Gate()
    private let sessions = LockedBox<Set<String>>([])
    /// Each MCP session's client, by the name it gave at initialize (routines and notes say who saved them).
    let clientNames = LockedBox<[String: String]>([:])
    var relay: RelayClient?
    /// The app's tools, after look, do and status in tools/list.
    private let hostTools = LockedBox<[HostTool]>([])
    private let sessionSignal = LockedBox<(@Sendable (SessionSignal) -> Void)?>(nil)

    /// Replaces the app's tools (none: only look, do and status are listed).
    public func setHostTools(_ tools: [HostTool]) {
        let own: Set<String> = ["look", "do", "routines", "status"]
        hostTools.value = tools.filter { !own.contains($0.name) }
    }
    /// Told when an MCP client's session starts or ends.
    public func onSession(_ handler: @escaping @Sendable (SessionSignal) -> Void) { sessionSignal.value = handler }

    public init(config: CoreConfig, host: CoreHost, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.host = host
        var c: AsyncStream<CoreEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c = $0 }
        continuation = c
        runner = Runner(url: config.runnerURL, transport: transport)
        runner.accessibilityDeadline = config.accessibilityDeadline
        runner.screenshotFallback = { [weak host] in await host?.screenshotWithoutRunner() }
        let emit: @Sendable (CoreEvent) -> Void = { [c] event in c!.yield(event) }
        approvals = Approvals(emit: emit)
        computer = Computer(runner: runner, host: host, config: config, approvals: approvals, emit: emit)
        // Two silent runner requests in a row: the runner is gone or stuck, so the launcher starts it again.
        runner.onUnhealthy = { [weak host, runner] in
            runner.forgetRunner()
            host?.restartRunner()
        }
    }

    func emit(_ event: CoreEvent) { continuation.yield(event) }

    /// Connects to the person's own relay and keeps it connected. There is no default relay: the app
    /// passes the address the person entered.
    public func start(relay address: RelayAddress, socketFactory: WebSocketFactory = URLSessionWebSocketFactory()) {
        guard relay == nil, let host else { return }
        let client = RelayClient(baseURL: address.phoneURL, host: host, factory: socketFactory, handler: { [weak self] request in
            await self?.handle(request) ?? RelayResponse(id: request.id, status: 503, headers: [:], body: "")
        }, emit: { [weak self] in self?.emit(.relay($0)) })
        client.undelivered = { [weak self] request, response in self?.keepLost(request, response) }
        relay = client
        client.start()
    }

    public func stop() {
        relay?.stop()
        relay = nil
    }

    /// Answers whose connection dropped before they could be sent; the next call carries them.
    let lost = LockedBox<[String]>([])
    func keepLost(_ request: RelayRequest, _ response: RelayResponse) {
        guard let body = try? JSON.parse(response.body), let text = body["result"]?["content"]?[0]?["text"]?.string else { return }
        let name = (try? JSON.parse(request.body))?["params"]?["name"]?.string ?? "call"
        let stamp = clock.string(from: Date())
        lost.update { $0 = Array(($0 + ["the \(name) call whose connection dropped (finished at \(stamp)): " + text]).suffix(3)) }
    }
    private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// The connector secrets changed: tell the relay the new list.
    public func accessChanged() { relay?.sendAccess() }

    public func resolveApproval(id: String, approved: Bool) { approvals.resolve(id: id, approved: approved) }

    /// The owner tapped Done on a step the model handed to them (the Live Activity).
    public func handoffDone(id: String) { computer.handoffDone(id: id) }
    /// The step the model handed to the owner that is still waiting, if any.
    public var handoff: Handoff? { computer.handoff.value.flatMap { $0.done == nil ? $0 : nil } }

    public var pendingApproval: Approval? { approvals.pending }

    /// A tap another part of the app sends without `do` (the Voice tab taps through the Mac's Poki MCP),
    /// on the element that reads `text` in the app in front. It is checked with the rules `do` uses and,
    /// when they say so, waits for the owner's OK on the phone, with the same approval (card, Live
    /// Activity, notification). A request still open after `seconds` is withdrawn. A tap in Poki itself
    /// is refused.
    public func clearTap(on text: String, inApp bundleID: String?, named name: String?, waiting seconds: Double) async -> TapClearance {
        let app = Foreground(bundleID: bundleID, name: name)
        // The approval card is in Poki: a tap there is refused, and the request waiting stays for the owner.
        if config.isPoki(app) { return .refused(CoreConfig.ownAppRefusal) }
        // Like `do`: a tap withdraws the request still waiting, so two taps never wait side by side.
        if let pending = approvals.pending { approvals.withdraw(id: pending.id) }
        let element = Element(type: "Other", label: text, value: nil, identifier: nil, frame: Rect(x: 0, y: 0, width: 0, height: 0), depth: 0)
        // No readable text: the rules cannot tell what it does, so the owner is asked.
        let unreadable = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let reason = unreadable && config.sensitive.enabled ? "a tap on something with no readable text" : config.sensitive.reason(touching: element, typing: false, app: app, secureOnScreen: false) else { return .clear }
        let approval = approvals.request(app: app.describe, summary: unreadable ? "Tap something with no text" : "Tap “\(text)”", reason: reason, fingerprint: "tap:\(UUID().uuidString)")
        switch await approvals.wait(id: approval.id, seconds: seconds) {
        case .approved?:
            _ = approvals.consumeGrant(fingerprint: approval.fingerprint)
            return .approved(reason)
        case .declined?:
            return .declined(reason)
        case .expired?:
            return .unanswered(reason)
        case nil:
            approvals.withdraw(id: approval.id)
            return .unanswered(reason)
        }
    }

    /// look, do or status for another part of the app (the Voice tab), run here on the phone exactly as a
    /// relay call: same gate, approvals, Live Activity and deadlines. `arguments` is the call's JSON object.
    public func tool(_ name: String, arguments: String) async -> ToolResult {
        guard let args = try? JSON.parse(arguments.isEmpty ? "{}" : arguments) else {
            return ToolResult(text: "error: the arguments are not JSON; nothing was sent", jpeg: nil, isError: true)
        }
        return await call(name, args)
    }

    /// The task is over (the app stops an idle runner, or its chat's turn ended): the phone goes back
    /// to the app the task began in. Nothing happens while a tool call runs or when no task is open.
    /// `switching: false` only forgets the task, for a runner the owner stopped: nothing is sent to it.
    public func finishTask(switching: Bool = true) async -> String? { await endTask(session: nil, switching: switching) }

    /// Only the session that began the task ends it; nil ends any.
    func endTask(session: String?, switching: Bool = true) async -> String? {
        guard await gate.enter(waiting: config.busyWait) else { return nil }
        defer { gate.leave() }
        if let session, computer.origin?.session != session { return nil }
        guard switching else { computer.origin = nil; return nil }
        return await computer.returnToOrigin()
    }

    // MARK: MCP over HTTP (Streamable HTTP, JSON answers only)

    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// The header Relay sets to the connector's secret hash, from the relay's own frame field.
    public static let connectorHeader = "x-poki-connector"

    public func handle(_ request: RelayRequest) async -> RelayResponse {
        func answer(_ status: Int, _ body: JSON?, session: String? = nil) -> RelayResponse {
            var headers = ["content-type": "application/json"]
            if let session { headers["mcp-session-id"] = session }
            return RelayResponse(id: request.id, status: status, headers: headers, body: body?.serialized() ?? "")
        }
        switch request.method {
        case "GET": return RelayResponse(id: request.id, status: 405, headers: ["allow": "POST, DELETE"], body: "")
        case "DELETE":
            // The client ended its session: when it began the task, the task is over too.
            if let s = request.headers["mcp-session-id"] {
                _ = sessions.update { $0.remove(s) }
                clientNames.update { $0[s] = nil }
                sessionSignal.value?(.ended(id: s))
                _ = await endTask(session: s)
            }
            return RelayResponse(id: request.id, status: 200, headers: [:], body: "")
        case "POST": break
        default: return RelayResponse(id: request.id, status: 405, headers: ["allow": "POST, DELETE"], body: "")
        }
        guard let message = try? JSON.parse(request.body) else {
            return answer(400, rpcError(nil, -32700, "Parse error"))
        }
        let session = request.headers["mcp-session-id"]
        if let batch = message.array {
            var replies: [JSON] = []
            for item in batch { if let r = await rpc(item, session: session, answerBy: request.answerBy, connector: request.headers[Self.connectorHeader]).reply { replies.append(r) } }
            return replies.isEmpty ? RelayResponse(id: request.id, status: 202, headers: [:], body: "") : answer(200, .array(replies), session: session)
        }
        let (reply, newSession) = await rpc(message, session: session, answerBy: request.answerBy, connector: request.headers[Self.connectorHeader])
        guard let reply else { return RelayResponse(id: request.id, status: 202, headers: [:], body: "") }
        return answer(200, reply, session: newSession ?? session)
    }

    func rpcError(_ id: JSON?, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    func rpc(_ message: JSON, session: String?, answerBy: Double? = nil, connector: String? = nil) async -> (reply: JSON?, session: String?) {
        let id = message["id"]
        guard let method = message["method"]?.string else { return (id == nil ? nil : rpcError(id, -32600, "Invalid Request"), nil) }
        let isNotification = id == nil
        func result(_ value: JSON) -> JSON { ["jsonrpc": "2.0", "id": id ?? .null, "result": value] }
        switch method {
        case "initialize":
            host?.warmUp()
            let asked = message["params"]?["protocolVersion"]?.string ?? Self.protocolVersions[0]
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            let newSession = UUID().uuidString.lowercased()
            sessions.update { _ = $0.insert(newSession) }
            let info = message["params"]?["clientInfo"]
            sessionSignal.value?(.started(id: newSession, client: info?["name"]?.string ?? "An agent", version: info?["version"]?.string, connector: connector))
            if let client = message["params"]?["clientInfo"]?["name"]?.string, !client.isEmpty { clientNames.update { $0[newSession] = String(client.prefix(40)) } }
            return (result([
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "poki", "version": "1.0"],
                "instructions": .string(Self.instructions),
            ]), newSession)
        case "notifications/initialized", "notifications/cancelled": return (nil, nil)
        case "ping": return (isNotification ? nil : result(.object([:])), nil)
        case "tools/list": return (result(["tools": .array(Self.tools + hostTools.value.map(\.listing))]), nil)
        case "tools/call":
            let name = message["params"]?["name"]?.string ?? ""
            let args = message["params"]?["arguments"] ?? .object([:])
            // A session Poki never saw begin (it began before Poki last started): the app is told,
            // so it can name the client from what it kept (the connector's agent, the last client).
            if let session, clientNames.value[session] == nil {
                clientNames.update { $0[session] = "" }
                sessionSignal.value?(.started(id: session, client: "", version: nil, connector: connector))
            }
            let output = await call(name, args, session: session, answerBy: answerBy)
            var content: [JSON] = [["type": "text", "text": .string(output.text)]]
            if let jpeg = output.jpeg { content.append(["type": "image", "data": .string(jpeg.base64EncodedString()), "mimeType": "image/jpeg"]) }
            return (result(["content": .array(content), "isError": .bool(output.isError)]), nil)
        default:
            if isNotification { return (nil, nil) }
            return (rpcError(id, -32601, "Method not found: \(method)"), nil)
        }
    }

    // MARK: Tools

    static let instructions = "look reads the iPhone's screen; do runs actions and then reads it. Both return the app in front, numbered elements and a screenshot whose pixels are screen points. Use the numbers from the latest answer; an element that stays on screen keeps its number, and do lists only what changed. Decide what happened from the elements, the screen_changed line and the picture. To reach something further down a list, use scroll_to with its text before trying swipes. Some actions (payments, deleting, sending messages, calls, passwords) need the owner's approval on the phone; do says so instead of sending them. Only the owner approves, by hand: do takes no input inside the Poki app. When the tree is late the elements come from the picture and a tap on a point of the picture always works: there is always a way on. A step that is the owner's to do (a password, a verification, a checkout you will not make) is handed to them with {handoff: {kind, text}}; keep polling look while they do it, then go on. When the owner's task is done, put finish: true on the last do (its actions may be empty): the phone then goes back to the app the owner asked from, where they read your reply. Saved routines repeat a whole path in one call: do {run: \"name\"} (routines {action: \"list\"} names them, and the first look of a task names those for the app in front); after a task that worked, routines {action: \"save\"} keeps its steps for next time, and remember keeps a fact about the owner."

    static let tools: [JSON] = [
        ["name": "look", "description": "Read the screen now: the app in front, the numbered elements (role, \"label = value\", [x,y,w,h] in screen points; + marks elements new since the last read, ~ moved ones) and a screenshot that is one pixel per screen point, so a point on the picture is a point to tap. Repeated text, scroll bars and empty containers are left out and long labels are cut; full=true lists every element as the tree has it and adds the text read from the picture inside [collapsed] elements (an app showed a whole cell, buttons and all, as one element). Numbers stay the same while an element stays on screen.",
         "inputSchema": ["type": "object", "properties": ["full": ["type": "boolean"]], "additionalProperties": false],
         "annotations": ["readOnlyHint": true]],
        ["name": "do", "description": "Run actions in order, then read the screen once. The answer says what each action did, screen_changed (true or false: whether the elements or the picture differ from the read before), and only the elements that are new (+) or moved (~); the others keep their numbers (full=true lists all). Actions: {run: \"routine name\"} or {run: {name, with: {text_1: \"…\"}}} (replays a saved routine in this one call: each step waits for its target and acts only on a single match, the end check is read, and it stops at the first screen that differs with the reason and the screen, from where you go on by hand; steps that need the owner's approval are handed back to you); {tap: n} or {tap: [x, y]} (a numbered element is tapped at its centre, or at the nearest free point when the tree puts something over its centre, and the answer says so; only an element with no part on the screen is refused as not_hittable); {type: \"text\", ref?: n, clear?: true, via?: \"paste\"} (taps n first, then types the text as key presses and says what the field holds afterwards; via paste is the backup when typing comes out wrong: it pastes through the field's menu and puts the owner's clipboard back); {key: \"return\"|\"delete\"|\"tab\"|\"space\"|\"escape\"}; {scroll_to: \"text\"} or {scroll_to: {text or ref, in?: n, direction?: \"down\", max_swipes?: 12}} (the best way to bring something into view: it scrolls until the text is fully on screen and says where, up to 12 s; when it stops short it says so and a second call goes on from there); {swipe: \"up\"|\"down\"|\"left\"|\"right\"} or {swipe: {direction, in?: n, distance?: \"short\"|\"long\"}} (a quick flick inside the biggest list on screen, or inside n, clear of bars; direction is where the finger moves, so up shows what is further down); {drag: {from: n or [x, y], to: n or [x, y], ms?: 400, hold_ms?: 0}} or {drag: [x1, y1, x2, y2]} (the content follows the finger and stops where it stops; hold_ms first to pick something up); {long_press: n or [x, y] or {ref, ms?}}; {pinch: {ref or x, y, scale}}; {button: \"home\"|\"lock\"|\"volume_up\"|\"volume_down\"}; {launch: \"bundle id\"} or {launch: {bundle, fresh: true}}; {wait_until: \"text\"} or {wait_until: {text, gone?: true, ms?: 3000}} or {wait_until: {settled: true, ms?}} (reads the screen until the text appears or goes, or the screen holds still; use it instead of fixed waits); {wait: ms}; {back: true} (the top-left back button if one is listed, else an edge swipe from the left); {handoff: {kind: \"passcode\"|\"password\"|\"verification\"|\"payment\"|\"other\", text: \"what the owner must do\"}} (when a step is the owner's to do, by your own judgement: it is shown on the phone with a Done button, no input is sent until they tap Done or you send {handoff: false}, and you keep polling with look or {wait_until: {handoff_done: true, ms?: 10000}} rather than ending your work). Points are screen points, like the frames and the screenshot's pixels. A locked phone takes nothing but buttons and says screen: locked. Each action is reported as sent, not_sent or unknown; it stops at the first action that fails. A type that fails or times out is checked against the focused field first: the text already there counts as typed, an empty field (its placeholder counts as empty) gets one more try, and a field holding anything else, half the text or other text, is not typed into again unless clear is set; no other action that may have been delivered is ever re-sent. Payments, deleting, sending messages and passwords need the owner's approval on the phone: the plain actions before the first such action are sent, the rest are not. do holds for the owner's answer (up to about two minutes, less behind a relay that gives up sooner) and goes on in the same call once they approve; when that time runs out the answer says approval_required and which actions to send again, on their own, after they approve. A runner still finishing an earlier request answers not_sent and busy; call look again then. finish: true on the do that completes the owner's task (actions may be empty): after the actions and the read, the phone goes back to the app the task began in, where the owner asked, so they see your reply there; leave it off while more steps follow.",
         "inputSchema": ["type": "object", "properties": ["actions": ["type": "array", "items": ["type": "object"], "minItems": 0, "maxItems": 20], "full": ["type": "boolean"], "finish": ["type": "boolean"]], "required": ["actions"], "additionalProperties": false]],
        routinesTool,
        ["name": "status", "description": "Poki's state without touching the phone: the runner, the relay, and any approval waiting on the phone.",
         "inputSchema": ["type": "object", "properties": .object([:]), "additionalProperties": false],
         "annotations": ["readOnlyHint": true]],
    ]

    /// A tool's answer for a caller in the app itself (the chat's model loop), without MCP framing.
    public struct ToolAnswer: Sendable {
        public let text: String
        public let jpeg: Data?
        public let isError: Bool
        public init(text: String, jpeg: Data?, isError: Bool) { self.text = text; self.jpeg = jpeg; self.isError = isError }
    }

    /// Calls `look`, `do` or `status` from inside the app, the same way an MCP client's `tools/call`
    /// does: one call at a time, the same approval rules, the same events. `arguments` is the JSON
    /// object the model sent.
    public func callTool(_ name: String, arguments: String) async -> ToolAnswer {
        let args = (try? JSON.parse(arguments)) ?? .object([:])
        let output = await call(name, args)
        return ToolAnswer(text: output.text, jpeg: output.jpeg, isError: output.isError)
    }

    /// The tools as MCP lists them (name, description, inputSchema), as a JSON array, and the
    /// instructions MCP clients get, for a model loop inside the app.
    public static var toolCatalogJSON: String { JSON.array(tools).serialized() }
    public static var toolInstructions: String { instructions }

    func call(_ name: String, _ args: JSON, session: String? = nil, answerBy: Double? = nil) async -> ToolResult {
        if name == "status" { return status() }
        if let tool = hostTools.value.first(where: { $0.name == name }) {
            // Outside the gate: the app's tool makes its own look and do calls, one at a time as any.
            let answer = await tool.run(args.serialized(), session, answerBy.map { max(0, $0 - now() - 3) })
            return ToolResult(text: answer.text, jpeg: answer.jpeg, isError: answer.isError)
        }
        if name == "routines" {
            // Memory only: no phone input, so it does not wait for a look or do in progress.
            let received = now()
            computer.lastCallTook = nil
            let result = routinesCall(args, session: session)
            computer.lastCallTook = now() - received
            return result
        }
        guard name == "look" || name == "do" else { return ToolResult(text: "unknown tool \(name); the tools are \((["look", "do", "routines", "status"] + hostTools.value.map(\.name)).joined(separator: ", "))", jpeg: nil, isError: true) }
        let received = now()
        computer.lastCallTook = nil
        let activity = ToolActivity(id: UUID().uuidString, name: name, summary: name == "do" ? computer.labels(args["actions"]?.array ?? []) : "Look at the screen", started: Date(), session: session)
        // One tool call at a time per phone; a second waits briefly, then says what the first is doing.
        guard await gate.enter(waiting: config.busyWait) else {
            // The screenshot is served apart from the runner's queue, so a busy answer still shows
            // the screen (the owner's rule: every answer carries the picture while the runner is up).
            return await computer.withPicture("busy: another call is still running (\(gate.current ?? "a tool")); nothing was sent. Call again in a moment.", timeout: 3, remember: false, isErrorWithoutPicture: false)
        }
        let gateWaited = now() - received
        gate.current = "\(name): \(activity.summary)"
        emit(.toolStarted(activity))
        // The owner's time on an approval, and the runner's start, come on top of the tool's own time.
        let deadline = (name == "do" ? computer.toolBudget(args["actions"]?.array ?? []) : config.toolDeadline) + (name == "do" ? config.approvalWait : 0) + config.runnerWait + 1
        var output: ToolResult
        computer.failureLog.value = nil
        do {
            output = try await withDeadline(deadline, name) { [computer] in
                name == "look" ? await computer.look(full: args["full"]?.bool ?? false, session: session) : await computer.act(actions: args["actions"]?.array ?? [], full: args["full"]?.bool ?? false, finish: args["finish"]?.bool ?? false, session: session, answerBy: answerBy)
            }
        } catch {
            // Never reached in practice (every step has its own deadline), but a call always answers.
            output = ToolResult(text: "error: \(error); what was sent is unknown. Call look to see the screen.", jpeg: nil, isError: true)
        }
        gate.current = nil
        gate.leave()
        // The MCP's own time around the tool (gym: a call measured 25.5 s outside against 9.2 s
        // inside): the wait for the call before, and the answer's making after.
        if let inside = computer.lastCallTook, now() - received - inside > 2 {
            let after = now() - received - inside - gateWaited
            do {
                output.text += "\nat the MCP: \(Computer.seconds(now() - received)) s from the request to this answer, \(Computer.seconds(inside)) s of it the tool's own\(gateWaited > 0.5 ? ", \(Computer.seconds(gateWaited)) s waiting for the call before to finish" : "")\(after > 0.5 ? ", \(Computer.seconds(after)) s making the answer" : "")"
            }
        }
        let earlier = lost.update { l -> [String] in defer { l = [] }; return l }
        if !earlier.isEmpty {
            output.text = "earlier, never delivered to you: " + earlier.joined(separator: "\n\n") + "\n\nnow:\n" + output.text
        }
        let line = output.text.split(separator: "\n").first.map(String.init) ?? ""
        let thumbnail = computer.lastPNG.flatMap { try? host?.jpeg(fromPNG: $0, width: 96, quality: 0.5) }
        // The log keeps the error line too: the step's own wording (it names what a field held by case
        // only), or the answer's first `error:` line. What the call typed is taken out of it either way
        // (a runner's error can echo it). A failed action with a read is not an isError answer (the
        // owner's rule: never an answer that halts the model), so the line is kept whenever there is one.
        var errorLine: String?
        if let found = computer.failureLog.value.map({ "error: \($0)" }) ?? output.text.split(separator: "\n").first(where: { $0.hasPrefix("error:") }).map(String.init) {
            var text = found
            for typed in (args["actions"]?.array ?? []).compactMap({ $0["type"]?.text }).filter({ $0.count >= 2 }).sorted(by: { $0.count > $1.count }) {
                text = text.replacingOccurrences(of: typed, with: "…")
            }
            errorLine = String(text.prefix(300))
        }
        emit(.toolFinished(activity, output.isError ? .failed(line) : .done(line), ToolFacts(app: computer.lastForeground?.describe, thumbnail: thumbnail, error: errorLine)))
        return output
    }

    func status() -> ToolResult {
        var lines = ["runner: \(host?.runnerState().describe ?? "unknown")"]
        if let relay { lines.append("relay: \(relay.stateDescription)") }
        if let p = approvals.pending { lines.append("approval waiting on the phone: \(p.summary) (\(p.reason), id \(p.id))") }
        if let line = computer.handoffLine(clear: false) { lines.append(line) }
        if let current = gate.current { lines.append("running: \(current)") }
        return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
    }
}

/// One holder at a time, with a bounded wait to get in.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var _current: String?
    var current: String? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); _current = newValue; lock.unlock() }
    }
    func tryEnter() -> Bool { lock.lock(); defer { lock.unlock() }; if held { return false }; held = true; return true }
    func enter(waiting seconds: Double) async -> Bool {
        let until = now() + seconds
        while true {
            if tryEnter() { return true }
            if now() >= until { return false }
            await sleep(seconds: 0.05)
        }
    }
    func leave() { lock.lock(); held = false; lock.unlock() }
}


extension HostTool {
    /// The tool as tools/list shows it.
    var listing: JSON {
        let schema = (try? JSON.parse(schemaJSON)) ?? ["type": "object"]
        return ["name": .string(name), "description": .string(description), "inputSchema": schema]
    }
}
