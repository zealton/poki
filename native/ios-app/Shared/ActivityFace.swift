import Foundation

typealias PokiState = PokiActivityAttributes.ContentState

/// What the Live Activity shows for a state, worked out once per phase. The Lock Screen, the expanded
/// island, the compact island and the minimal view all draw this, so the four presentations always say
/// the same thing in the same order.
///
/// The one fact to read at a glance is what Poki is doing on the phone right now, or what it needs
/// from you. Every presentation is built around it: a state glyph in the state's colour (the same glyph
/// in all four), a short status word, and in the larger presentations the content line (the step, the
/// question, the result) in the large size. Below it there is at most one action: Stop while working,
/// the Allow/Deny decision while an approval waits, or Done for a step handed to you. Progress is a bar
/// only where there is a real total (setup's steps); an agent's run has no known length, so it shows
/// the step number, not a bar.
struct ActivityFace: Hashable {
    enum Meta: Hashable {
        case none
        /// A short count ("Step 7", "2/6") or a duration.
        case text(String)
        /// The time left on an approval, counted down by the system.
        case countdown(Date)
        /// A time of day ("9:41 AM").
        case clock(Date)
        /// How long the agent has waited for the person, counted up by the system.
        case elapsed(Date)
    }
    enum Compact: Hashable {
        /// A short word or count ("Step 7", "2/6", "Done").
        case text(String, ActivityTone)
        /// The pairing code, tabular digits.
        case code(String)
        case countdown(Date)
        case elapsed(Date)
    }
    enum Bottom: Hashable {
        case none
        /// Stop, beside the content line, while the agent is working.
        case stop
        case approval(id: String)
        /// "I'm Done" for a screen the agent handed to the person.
        case handoff(id: String)
        /// A real fraction (setup: steps done of all steps).
        case progress(Double)
    }

    /// The SF Symbol for the state, drawn in `tone` in every presentation.
    var symbol: String
    /// The status word ("Approval"), coloured by `tone`.
    var status: String
    /// The same, short enough for the expanded island's leading region and the compact island.
    var shortStatus: String
    var tone: ActivityTone
    /// The value at the status word's right, on the Lock Screen and beside the camera.
    var meta: Meta
    /// The content line, the one thing in the large size.
    var content: String
    /// The content is the pairing code.
    var contentIsCode = false
    var bottom: Bottom
    var compact: Compact
    /// Outline the island while the person is needed.
    var outlined = false
    /// The screen a tap opens.
    var link: URL = ActivityLink.chat
    /// The app has not updated the activity for longer than it should have: what it shows may be old.
    var stale = false
    /// Who is calling: the outside agent whose badge sits beside the meta value.
    var caller: String?
    /// The run's latest steps for the step bar (true went through), and whether one is under way.
    var steps: [Bool] = []
    var stepUnderWay = false
    var finished = false
    var agentTask: PokiActivityAttributes.AgentTask?
    var snapshotID: String?
    var snapshotAt: Date?
    var hasSnapshot = false
    /// The ring around the glyph in the compact and minimal island.
    var ring: Ring = .none

    enum Ring: Hashable {
        case none
        /// A share of the step bar filled.
        case fraction(Double)
        /// Time left on an approval, run down by the system.
        case timer(ClosedRange<Date>)
    }

    /// Approval/handoff content keeps its full text and controls instead of the optional trace.
    var showsAgentTrace: Bool {
        guard agentTask != nil else { return false }
        switch bottom { case .none, .stop: return true; default: return false }
    }

    var hasAction: Bool {
        switch bottom {
        case .stop, .approval, .handoff: true
        default: false
        }
    }
}

/// Where a tap on the Live Activity goes, handled by RootView's onOpenURL.
enum ActivityLink {
    /// The chat that runs the agent (also approvals and handoffs, which the chat shows).
    static let chat = URL(string: "poki://chat")!
    /// The Activity Log, where a problem's details are.
    static let log = URL(string: "poki://log")!
    static func setup(_ step: String? = nil) -> URL {
        URL(string: step.map { "poki://setup?step=\($0)" } ?? "poki://setup")!
    }
}

extension PokiActivityAttributes.Event {
    var tone: ActivityTone {
        switch kind {
        case .started, .app, .code, .resumed: .accent
        case .handoff: .approval
        case .finished, .approved, .paired: .done
        case .denied, .expired: .quiet
        case .problem: .problem
        }
    }
}

extension PokiState {
    var hasThumbnail: Bool { thumbnailVersion > 0 }

    /// "12 steps in 1:24".
    var runLine: String {
        let steps = stepCount == 1 ? String(activity: "1 step") : String(activity: "\(stepCount) steps")
        guard let since, let endedAt else { return steps }
        let time = Duration.seconds(max(0, endedAt.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond))
        return String(activity: "\(steps) in \(time)")
    }

    /// The finished run for the alert: "12 steps in 1:24, 1 missed".
    var runSummary: String {
        failedCount > 0 ? String(activity: "\(runLine), \(failedCount) missed") : runLine
    }

    var face: ActivityFace { face(stale: false) }

    /// The face for the widget: `stale` when ActivityKit says the content is past its stale date.
    func face(stale: Bool) -> ActivityFace {
        var face = baseFace
        face.caller = caller
        face.agentTask = agentTask
        face.snapshotID = snapshotID; face.snapshotAt = snapshotAt; face.hasSnapshot = hasThumbnail
        if phase == .working, let task = agentTask {
            face.symbol = task.background ? "rectangle.on.rectangle" : "hand.tap.fill"
            face.stepUnderWay = !task.thinking
            if let stage = task.stage { face.content = stage }
            if let current = task.current, let total = task.total, total > 0 {
                face.ring = .fraction(Double(current - 1) / Double(total))
            } else { face.ring = .none }
            if task.thinking { face.compact = .text(String(activity: "Thinking"), .plain) }
        }
        if phase == .idle, agentTask?.active == false, agentTask?.stopped == true {
            let word = String(activity: "Stopped")
            face.symbol = "stop.circle"; face.status = word; face.shortStatus = word
            face.tone = .quiet; face.meta = .none; face.compact = .text(word, .quiet)
        }
        // A fresh event ("Started", "Allowed") takes the status word's place for a few seconds, in
        // its own colour. An app switch keeps the app's name as the word and only lights it up.
        if let event, !phase.holdsApproval {
            let word = event.kind == .app ? (app ?? event.text) : ActivityWords.local(event.text)
            face.status = word
            face.shortStatus = word
            face.tone = event.tone
            // Compact text and its adjacent glyph are one status. A transient
            // event must not recolor only the glyph (for example blue + green Ready).
            if case .text(let text, _) = face.compact {
                face.compact = .text(text, event.tone)
            }
        }
        if stale, phase == .working || phase == .handoff {
            // The app stopped updating (closed, or iOS suspended it): say so, and drop the action,
            // which needs the app.
            let word = String(activity: "Not updating")
            face.symbol = "clock.badge.exclamationmark"
            face.status = word
            face.shortStatus = String(activity: "Paused")
            face.tone = .quiet
            face.meta = .none
            face.bottom = .none
            face.compact = .text(String(activity: "Paused"), .quiet)
            face.outlined = false
            face.stale = true
        }
        return face
    }

    private var baseFace: ActivityFace {
        let step = String(activity: "Step \(stepCount + 1)")
        switch phase {
        case .working:
            let name = app ?? String(activity: "Working")
            return ActivityFace(
                symbol: "hand.tap.fill", status: name, shortStatus: name, tone: .accent, meta: .text(step),
                content: ActivityWords.step(headline), bottom: .stop,
                compact: .text(step, .plain),
                steps: outcomes, stepUnderWay: true,
                ring: .fraction(Double(outcomes.count) / Double(Self.outcomeLimit)))
        case .approval, .deciding:
            guard let approval else { return quietFace }
            let question = ActivityWords.brief(approval.question)
            if phase == .deciding {
                let allowed = decision == true
                let word = allowed ? String(activity: "Allowed") : String(activity: "Denied")
                return ActivityFace(
                    symbol: allowed ? "checkmark.circle.fill" : "xmark.circle.fill",
                    status: word, shortStatus: word, tone: allowed ? .done : .quiet, meta: .none,
                    content: question, bottom: .none,
                    compact: .text(word, allowed ? .done : .quiet))
            }
            let word = String(activity: "Approval")
            return ActivityFace(
                symbol: "hand.raised.fill", status: word, shortStatus: word, tone: .approval,
                meta: .countdown(approval.expires),
                content: question, bottom: .approval(id: approval.id),
                compact: .countdown(approval.expires),
                outlined: true,
                ring: .timer(Countdown.range(approval.expires)))
        case .done:
            let word = String(activity: "Done")
            return ActivityFace(
                symbol: "checkmark.circle.fill", status: word, shortStatus: word, tone: .done,
                meta: endedAt.map { .clock($0) } ?? .none,
                content: runSummary, bottom: .none,
                compact: .text(word, .done),
                steps: outcomes, finished: true,
                ring: .fraction(1))
        case .problem:
            let short = label == "Pairing Failed" ? String(activity: "Failed") : String(activity: "Stopped")
            return ActivityFace(
                symbol: "exclamationmark.triangle.fill",
                status: ActivityWords.local(label ?? "Problem"), shortStatus: short,
                tone: .problem, meta: .none,
                content: ActivityWords.brief(ActivityWords.local(headline)), bottom: .none,
                compact: .text(short, .problem),
                link: label == "Pairing Failed" ? ActivityLink.setup("pairing") : ActivityLink.log)
        case .pairing:
            if let pin {
                return ActivityFace(
                    symbol: "link", status: String(activity: "Pairing Code"), shortStatus: String(activity: "Pairing"),
                    tone: .accent, meta: .none,
                    content: pin.count == 6 ? "\(pin.prefix(3)) \(pin.suffix(3))" : pin, contentIsCode: true,
                    bottom: .none,
                    compact: .code(pin),
                    link: ActivityLink.setup("pairing"))
            }
            let word = String(activity: "Pairing")
            return ActivityFace(
                symbol: "link", status: word, shortStatus: word, tone: .accent, meta: .none,
                content: String(activity: "Pair in Settings"), bottom: .none,
                compact: .text(word, .accent),
                link: ActivityLink.setup("pairing"))
        case .setup:
            guard let guide else { return quietFace }
            let word = String(activity: "Setup")
            let count = "\(guide.number)/\(guide.count)"
            return ActivityFace(
                symbol: "checklist", status: word, shortStatus: word, tone: .accent, meta: .text(count),
                content: ActivityWords.brief(ActivityWords.local(guide.title)),
                bottom: .progress(Double(max(0, guide.number - 1)) / Double(max(1, guide.count))),
                compact: .text(count, .plain),
                link: ActivityLink.setup())
        case .handoff:
            guard let handoff else { return quietFace }
            let word = String(activity: "Your turn")
            return ActivityFace(
                symbol: handoff.symbol, status: word, shortStatus: word, tone: .approval, meta: .elapsed(handoff.since),
                content: ActivityWords.brief(handoff.line),
                bottom: .handoff(id: handoff.id),
                compact: .elapsed(handoff.since),
                outlined: true)
        case .idle:
            return quietFace
        }
    }

    /// Ready (the runner is up) and Idle (it sleeps until an agent asks).
    private var quietFace: ActivityFace {
        let word = runnerPaused ? String(activity: "Idle") : String(activity: "Ready")
        return ActivityFace(
            symbol: runnerPaused ? "moon.fill" : "checkmark.circle", status: word, shortStatus: word,
            tone: runnerPaused ? .quiet : .done, meta: .none,
            content: ActivityWords.brief(ActivityWords.local(headline)), bottom: .none,
            compact: .text(word, runnerPaused ? .quiet : .done))
    }
}

extension PokiActivityAttributes.Handoff {
    /// What the person has to do, in the agent's place.
    var title: String {
        switch kind {
        case .runnerPasscode: String(activity: "Enter your passcode to start the runner")
        case .automationPasscode: String(activity: "Enter your passcode to allow automation")
        case .passcode: String(activity: "Enter your passcode")
        case .password: String(activity: "Fill in your password")
        case .verification: String(activity: "Pass the verification yourself")
        case .payment: String(activity: "Finish the payment yourself")
        case .other: String(activity: "Do this step yourself")
        }
    }
    /// The content line: a fixed short line per kind, so it fits the Live Activity's four words (eight
    /// characters in Chinese) whole. The agent's own note is the alert's second line (`detail`) and
    /// the app's issue row, where it has room.
    var line: String {
        switch kind {
        case .runnerPasscode: String(activity: "Passcode for the runner")
        case .automationPasscode: String(activity: "Passcode for automation")
        default: title
        }
    }
    /// The agent's own note, or what happens next (the alert's second line).
    var detail: String {
        if let text, !text.isEmpty { return text }
        switch kind {
        case .runnerPasscode: return String(activity: "iOS asks for it once after a restart. The agent waits.")
        case .automationPasscode: return String(activity: "iOS asks after Poki restarts or 8 hours later. The agent waits.")
        case .payment: return String(activity: "The agent does not pay for you. It waits, then carries on.")
        default: return String(activity: "The agent can't act on this screen. It waits for you.")
        }
    }
    var symbol: String {
        switch kind {
        case .runnerPasscode, .automationPasscode, .passcode: "lock.fill"
        case .password: "key.fill"
        case .verification: "checkmark.shield.fill"
        case .payment: "creditcard.fill"
        case .other: "person.fill"
        }
    }
}
