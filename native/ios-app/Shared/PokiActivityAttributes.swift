// The Live Activity's shared data. Phase layout and the terminal flag follow AgentActivityAttributes.swift
// from Clarklevis1995/dsh-mobile (commit ebe19764, DeepSeekHarnessMobile/LiveActivity/AgentActivityAttributes.swift),
// MIT License, Copyright (c) 2026 Chaofan Li. See THIRD_PARTY_NOTICES.md.
import ActivityKit
import Foundation

/// The Live Activity's data, shared by the app (which starts and updates it) and the widget extension
/// (which draws it). ActivityKit caps the payload at 4 KB, so the screenshot thumbnail is not in it:
/// the app writes it to the App Group container and the state carries only its version.
struct PokiActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `done` follows the chat’s explicit result (legacy external sessions use a quiet-period
        /// heuristic); `deciding` by AppModel the moment Allow or Deny is tapped on the Live Activity,
        /// until PokiCore has the answer. `handoff`: the agent cannot act on this screen (a passcode, a
        /// verification, a payment) and the person has to; the agent keeps polling meanwhile. See `Handoff`.
        enum Phase: String, Codable, Hashable {
            case idle, working, approval, deciding, pairing, setup, problem, done, handoff

            /// The phases a person has to answer: a step from the agent never replaces them.
            var holdsApproval: Bool { self == .approval || self == .deciding }
        }
        var phase: Phase
        /// What the agent is doing, in a few words ("Tap “Send”"), or the phase's line, in English: the
        /// face words it in the system's language (ActivityWords).
        var headline: String
        /// The status word in place of the phase's own ("Runner Stopped").
        var label: String?
        /// The app in front.
        var app: String?
        /// The outside agent driving the phone ("Claude Code"), nil for Poki's own chat.
        var caller: String?
        /// Bumped whenever a new thumbnail is written to the App Group container.
        var thumbnailVersion: Int
        /// A pending approval, if any. Its buttons are App Intents; see ApprovalIntents.swift.
        var approval: PendingApproval?
        /// While `deciding`: true for Allow, false for Deny.
        var decision: Bool?
        /// What the person has to do themselves, while phase is `handoff`.
        var handoff: Handoff?
        /// The pairing PIN while on-device pairing is waiting for it.
        var pin: String?
        /// The runner is stopped while no agent uses the phone (no automation banner); the next
        /// request starts it again.
        var runnerPaused = false
        /// Whether each of the run's latest steps went through, newest last, at most `outcomeLimit`.
        var outcomes: [Bool] = []
        /// During setup: which step the person is on ("2/6").
        var guide: Guide?
        /// When the agent's current run of steps began.
        var since: Date?
        /// Steps in the current run, and how many of them did not go through. Kept by ActivityController.
        var stepCount = 0
        var failedCount = 0
        /// When the run finished (phase `done`), so the summary shows a fixed duration.
        var endedAt: Date?
        /// A short-lived event ("Started", "Now in WeChat", "Allowed") shown as the status word for a few
        /// seconds. ActivityController clears it.
        var event: Event?
        /// Optional so activities created by an earlier version still decode.
        var agentTask: AgentTask?
        /// Immutable App Group image; the state never carries image bytes or a file-system path.
        var snapshotID: String?
        var snapshotAt: Date?

        static let outcomeLimit = 12
    }
    struct Event: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case started, app, finished, approved, denied, expired, problem, paired, code, handoff, resumed }
        var kind: Kind
        var text: String
    }
    /// The agent (or the runner's launch) handed a screen to the person. `kind` picks the words and
    /// the symbol; `text` is the agent's own one-line note of what is needed, if any. The person taps
    /// Done on the Live Activity when finished (HandoffDoneIntent), which the app passes on to PokiCore.
    struct Handoff: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case runnerPasscode, automationPasscode, passcode, password, verification, payment, other }
        var id: String
        var kind: Kind
        var text: String?
        var app: String?
        var since: Date
    }
    struct Guide: Codable, Hashable {
        var number: Int
        var count: Int
        var title: String
    }
    var deviceName: String
}

extension PokiActivityAttributes {
    struct AgentTask: Codable, Hashable {
        struct Step: Codable, Hashable {
            enum Status: String, Codable, Hashable { case running, done, failed, stopped }
            var title: String
            var status: Status
        }
        var id: UUID
        var background: Bool
        var active = true
        var thinking = true
        var stopped: Bool?
        var stage: String?
        var current: Int?
        var total: Int?
        var steps: [Step] = []

        /// A short operation label, never a raw argument payload or model reasoning.
        static func label(_ text: String) -> String {
            let clean = text
                .replacingOccurrences(of: #"(?i)(?:sk-[a-z0-9_-]{12,}|bearer\s+\S+)"#, with: "…", options: .regularExpression)
                .replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
            var result = ""
            for character in clean {
                guard result.utf8.count + String(character).utf8.count <= 120 else { break }
                result.append(character)
            }
            return result
        }

        mutating func start(_ title: String) {
            if steps.last?.status == .running { steps[steps.count - 1].status = .stopped }
            steps.append(Step(title: Self.label(title), status: .running))
            steps = Array(steps.suffix(3))
            thinking = false
        }
        mutating func complete(_ title: String, ok: Bool) {
            let title = Self.label(title)
            if steps.last?.status == .running, steps.last?.title == title {
                steps[steps.count - 1].status = ok ? .done : .failed
            } else {
                steps.append(Step(title: title, status: ok ? .done : .failed))
                steps = Array(steps.suffix(3))
            }
            thinking = true
        }
    }
}

struct PendingApproval: Codable, Hashable {
    var id: String
    var app: String
    var summary: String
    /// Why it needs the owner, from PokiCore's rules: `sending a message ("send")`, `a payment ("pay")`.
    var reason: String
    var expires: Date

    /// The approval as a short question, from PokiCore's reason and the app: "Send in Messages?".
    /// The summary ("Tap “Send”") says how, which the thumbnail shows better.
    var question: String {
        // PokiCore names the app, or says "unknown", or describes the home screen at length.
        let place = app.isEmpty || app == "unknown" || app.contains("(") ? nil : app
        if reason.hasPrefix("sending") { return place.map { String(activity: "Send in \($0)?") } ?? String(activity: "Send a message?") }
        if reason.hasPrefix("a payment") { return place.map { String(activity: "Pay in \($0)?") } ?? String(activity: "Make a payment?") }
        if reason.hasPrefix("deleting") { return place.map { String(activity: "Delete in \($0)?") } ?? String(activity: "Delete this?") }
        if reason.hasPrefix("typing into a password") { return String(activity: "Type a password?") }
        if reason.hasPrefix("input in"), let place { return String(activity: "Use \(place)?") }
        return String(activity: "Allow this step?")
    }
}

enum SharedContainer {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "PokiAppGroup") as? String ?? "group.nz.zheha.poki"
    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }
    static var thumbnailURL: URL? { url?.appendingPathComponent("activity-thumbnail.jpg") }
    static func snapshotURL(_ id: String?) -> URL? {
        guard let id, UUID(uuidString: id) != nil else { return nil }
        return url?.appendingPathComponent("activity-snapshots").appendingPathComponent(id + ".jpg")
    }
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
}
