// The sending path is ported from two Live Activity managers: the latest-wins coalescing worker, the
// ordered operation tail and the update policy from AgentLiveActivityManager.swift in
// Clarklevis1995/dsh-mobile (commit ebe19764, DeepSeekHarnessMobile/LiveActivity/), MIT License,
// Copyright (c) 2026 Chaofan Li; the token bucket from ios/IPhoneAgent/App/LiveActivity.swift in
// onehumanbeing/esp32-iphone-agent (commit cc966294), MIT License, Copyright (c) 2026 Henry Yuan.
// See THIRD_PARTY_NOTICES.md.
import ActivityKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runs the one Live Activity: started when a session starts, updated from PokiCore's events, ended
/// when the session stops or Poki closes.
///
/// AppModel only describes the state (`update`, `record`); this class decides what deserves a pop-up.
/// It compares each new state with the last one and, for the moments that matter, sends the update with
/// an `AlertConfiguration`, which lights the screen, expands the Dynamic Island and plays a sound:
///
/// - approval asked (always, never throttled): the screen lights even when locked;
/// - a run finishes (quiet for `finishAfter`), a problem, a pairing code, paired.
///
/// Never while the runner may be sending input: an alert expands the Dynamic Island over the top
/// of the screen, and on the owner's phone the agent's next tap (Back, a list's first row) landed
/// on the expanded island and opened Poki. So steps, the start of a run and app switches only
/// change the compact island and the Lock Screen (the event tag); they never expand it.
///
/// Sending: a state that needs the person (an approval, its answer, a problem, a pairing code, the
/// end of a run) goes out at once, in order. Plain progress waits 700 ms for the next one and only
/// the newest goes out, within a budget of two at once and then one a second, so a fast agent never
/// queues minutes of old steps behind the island.
@MainActor
final class ActivityController {
    private var activity: Activity<PokiActivityAttributes>?
    private(set) var state = PokiState(phase: .idle, headline: "Waiting for agent", thumbnailVersion: 0)
    private(set) var lastError: String?

    /// Legacy external sessions have no model-task boundary; infer their completion after this quiet period.
    var finishAfter: Duration = .seconds(15)
    /// How long the finished run stays before the activity folds back to Ready.
    var foldAfter: Duration = .seconds(30)

    /// How long an event tag stays on the Live Activity.
    private let eventLifetime: Duration = .seconds(6)
    /// Start, app switch and finish pop-ups are spaced this far apart.
    private let alertSpacing: TimeInterval = 6
    /// Plain progress waits this long for a newer state before it is sent.
    private static let coalescing: Duration = .milliseconds(700)

    private var lastAlert = Date.distantPast
    private var budget = UpdateBudget()
    private var plainWaiting = false
    private var worker: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var finishTimer: Task<Void, Never>?
    private var foldTimer: Task<Void, Never>?
    private var eventTimer: Task<Void, Never>?
    private var inStep = false
    private var runAnnounced = false
    private var justRecorded = false
    private let snapshotDirectory: URL?

    init(snapshotDirectory: URL? = SharedContainer.url?.appendingPathComponent("activity-snapshots")) {
        self.snapshotDirectory = snapshotDirectory
    }

    func beginAgentTask(_ id: UUID, background: Bool) {
        finishTimer?.cancel(); foldTimer?.cancel()
        update {
            $0.agentTask = .init(id: id, background: background)
            $0.snapshotID = nil; $0.snapshotAt = nil; $0.thumbnailVersion = 0
            $0.stepCount = 0; $0.failedCount = 0; $0.outcomes = []; $0.endedAt = nil
            $0.since = Date(); $0.app = nil
            if !$0.phase.holdsApproval, $0.handoff == nil { $0.phase = .working; $0.headline = String(activity: "Thinking") }
        }
    }

    func agentPlan(_ id: UUID, steps: [String], current: Int) {
        guard state.agentTask?.id == id, state.agentTask?.active == true, steps.indices.contains(current - 1) else { return }
        update {
            $0.agentTask?.stage = PokiActivityAttributes.AgentTask.label(steps[current - 1])
            $0.agentTask?.current = current; $0.agentTask?.total = steps.count
        }
    }

    func stepStarted(_ title: String) {
        update { $0.agentTask?.start(title) }
    }

    /// An explicit model-task boundary; an API response taking 15 seconds is not a completed task.
    func endAgentTask(_ id: UUID, success: Bool?, stopped: Bool) {
        guard state.agentTask?.id == id, state.agentTask?.active == true else { return }
        finishTimer?.cancel(); eventTimer?.cancel()
        update {
            $0.event = nil
            $0.agentTask?.active = false; $0.agentTask?.thinking = false; $0.agentTask?.stopped = stopped
            if var task = $0.agentTask, task.steps.last?.status == .running {
                task.steps[task.steps.count - 1].status = stopped ? .stopped : .failed
                $0.agentTask = task
            }
            guard !$0.phase.holdsApproval, $0.handoff == nil else { return }
            $0.endedAt = Date()
            if success == true, !stopped, var task = $0.agentTask { task.current = task.total; $0.agentTask = task }
            if stopped { $0.phase = .idle; $0.headline = String(activity: "Stopped") }
            else if success == true { $0.phase = .done; $0.headline = "Finished" }
            else if success == false { $0.phase = .problem; $0.label = String(activity: "Task failed"); $0.headline = String(activity: "Open Poki for details") }
            else { $0.phase = .idle; $0.headline = String(activity: "Waiting for you") }
        }
        if state.phase == .done { armFold() }
    }

    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var isRunning: Bool { activity != nil }

    /// Ends every Live Activity of Poki's: at launch, the ones a crashed or closed earlier run left
    /// behind (only this process updates its activity, so one it did not start is out of date); when
    /// Poki closes, its own, since nothing would update it after that. Detached, because Poki holds
    /// the main thread while it closes.
    nonisolated static func endAll() {
        let activities = Activity<PokiActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        Task.detached { for old in activities { await old.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Starts the Live Activity if it is not running. iOS only allows this while Poki is in front, so
    /// it is called when the person taps something (Start, Start pairing, a setup step), never later
    /// from the background.
    func start(deviceName: String) {
        guard activity == nil else { return }
        guard enabled else { lastError = "Live Activities are off for Poki (Settings > Poki > Live Activities)."; return }
        // A Live Activity left from an earlier run of the app is replaced.
        for old in Activity<PokiActivityAttributes>.activities { Task { await old.end(nil, dismissalPolicy: .immediate) } }
        do {
            let started = try Activity.request(attributes: PokiActivityAttributes(deviceName: deviceName), content: content(), pushType: nil)
            activity = started
            budget = UpdateBudget()
            lastError = nil
            // Dismissed by the person (swiped away) or ended by iOS: start again next time.
            Task { [weak self] in
                for await state in started.activityStateUpdates where state == .dismissed || state == .ended {
                    await MainActor.run { if self?.activity?.id == started.id { self?.activity = nil } }
                }
            }
        } catch { lastError = String(localized: "The Live Activity did not start: \(error.localizedDescription)") }
    }

    /// Counts a finished step for the step line and the run's summary.
    func record(step text: String, ok: Bool) {
        update { state in
            state.outcomes.append(ok)
            if state.outcomes.count > PokiState.outcomeLimit { state.outcomes.removeFirst(state.outcomes.count - PokiState.outcomeLimit) }
            state.stepCount += 1
            if !ok { state.failedCount += 1 }
            state.agentTask?.complete(text, ok: ok)
        }
        justRecorded = true
    }

    /// Ends the Live Activity at once, after the updates already on their way, so nothing is left on
    /// the Lock Screen or in the island.
    func end() {
        finishTimer?.cancel(); foldTimer?.cancel(); eventTimer?.cancel()
        worker?.cancel(); worker = nil; plainWaiting = false
        guard let activity else { return }
        self.activity = nil
        // A finished run or a problem stays on the Lock Screen with its final content for a while (HIG:
        // end at once, keep the outcome readable); anything else goes at once.
        let final: ActivityContent<PokiState>? = state.phase == .done || state.phase == .problem
            ? ActivityContent(state: state, staleDate: nil, relevanceScore: 0) : nil
        let policy: ActivityUIDismissalPolicy = final == nil ? .immediate : .after(.now.addingTimeInterval(15 * 60))
        state.outcomes = []; state.guide = nil; state.pin = nil; state.since = nil; state.event = nil
        state.stepCount = 0; state.failedCount = 0; state.endedAt = nil; state.decision = nil
        state.agentTask = nil; state.snapshotID = nil; state.snapshotAt = nil; state.thumbnailVersion = 0
        let previous = tail
        tail = Task { await previous?.value; await activity.end(final, dismissalPolicy: policy) }
    }

    func update(_ change: (inout PokiState) -> Void) {
        let old = state
        change(&state)
        ActivityUpdatePolicy.settle(&state, over: old)
        let proposed = transition(from: old)
        // Progress, completion and errors in an isolated task must not expand over the owner's app.
        let quietBackground = state.agentTask?.background == true && !state.phase.holdsApproval && state.handoff == nil
        let alert = quietBackground ? nil : proposed
        if quietBackground { attention = nil }
        // Something needs the person and there is no Live Activity to pop up: a banner instead (an
        // approval and a pairing code have their own).
        if let banner = attention, activity == nil {
            AttentionNotice.post(title: banner.title, body: banner.body)
        }
        attention = nil
        if state.handoff == nil, state.phase != .problem, old.handoff != nil || old.phase == .problem { AttentionNotice.clear() }
        send(alert: alert, critical: Self.isCritical(state, after: old))
    }
    /// The hand-off or problem this change pops up for (`update` posts a banner when no activity runs).
    private var attention: (title: String, body: String)?

    /// Writes a versioned thumbnail, at most 240 pixels wide, to the widget’s App Group container.
    func setThumbnail(_ jpeg: Data?) {
        guard let jpeg, let directory = snapshotDirectory, let small = Self.shrink(jpeg, maxPixels: 240) else { return }
        let id = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try small.write(to: directory.appendingPathComponent(id + ".jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { return }
        update { $0.thumbnailVersion += 1; $0.snapshotID = id; $0.snapshotAt = Date() }
        // Bound disk use while retaining old frames long enough for coalesced widget updates.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let ordered = files.filter { $0.pathExtension == "jpg" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in ordered.dropFirst(12) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: Transitions

    /// Fills in what the app does not track (run counters, the event tag) and returns the pop-up this
    /// change deserves, if any.
    private func transition(from old: PokiState) -> AlertConfiguration? {
        var alert: AlertConfiguration?
        let now = Date()
        // A problem's own word goes with it.
        if state.phase != .problem { state.label = nil }

        // A new run of steps: from anything that is not already a run.
        let runPhases: Set<PokiState.Phase> = [.working, .approval, .deciding, .handoff]
        if state.phase == .working, !runPhases.contains(old.phase) {
            state.stepCount = 0; state.failedCount = 0; state.endedAt = nil; state.outcomes = []
            if state.since == nil { state.since = now }
            // The runner's start and the agent's first step are one start.
            if !runAnnounced {
                runAnnounced = true
                setEvent(.started, "Started")
            }
        }
        if state.phase == .done || state.phase == .idle && state.runnerPaused || state.phase == .pairing || state.phase == .setup {
            runAnnounced = false
        }
        if state.phase != .done { foldTimer?.cancel() }
        // Into another app mid-run.
        if runPhases.contains(state.phase), let app = state.app, let before = old.app, app != before {
            setEvent(.app, app)
            // No pop-up: the runner is in the middle of acting.
        }
        // Your turn: the agent handed the screen to the person. Pops up and lights the screen; the
        // runner sends nothing while it waits, so the expanded island is safe. The run goes on after.
        if let handoff = state.handoff, handoff.id != old.handoff?.id {
            setEvent(.handoff, "Your turn")
            alert = critical(handoff.title, handoff.detail)
            attention = (handoff.title, handoff.detail)
        }
        if state.handoff == nil, old.handoff != nil, state.phase == .working {
            setEvent(.resumed, "Carrying on")
        }
        // Approval: always pops up and lights the screen.
        if let approval = state.approval, approval.id != old.approval?.id {
            alert = critical(String(activity: "Allow this step?"), approval.question)
        }
        if state.approval == nil, let was = old.approval {
            state.decision = nil
            let approved = state.headline == "Continuing"
            let expired = !approved && was.expires <= now.addingTimeInterval(0.5)
            setEvent(approved ? .approved : expired ? .expired : .denied, approved ? "Allowed" : expired ? "Timed out" : "Denied")
        }
        if state.phase == .problem, old.phase != .problem {
            setEvent(.problem, state.label ?? "Problem")
            alert = critical(String(activity: "Poki needs attention"), ActivityWords.local(state.headline))
            attention = (String(activity: "Poki needs attention"), ActivityWords.local(state.headline))
        }
        if let pin = state.pin, pin != old.pin {
            setEvent(.code, "Code ready")
            alert = critical(String(activity: "Pairing code \(pin)"), String(activity: "Type it on the Pair with Poki screen in Settings"))
        }
        if old.phase == .pairing, state.phase == .idle, state.headline == "Paired" {
            setEvent(.paired, "Paired")
            alert = critical(String(activity: "Paired"), String(activity: "This iPhone is ready for Poki"))
        }

        // A step began (AppModel sets the headline to the step's words): shown, never popped up.
        if state.phase == .working, old.phase == .working, state.headline != old.headline, state.stepCount == old.stepCount {
            if justRecorded { justRecorded = false } else { inStep = true }
        }
        if state.stepCount != old.stepCount { inStep = false }
        // The finish timer: re-armed by every change during a run; never fires in the middle of a step.
        if state.phase == .working, state.agentTask?.active != true, state.approval == nil, state.handoff == nil, state.stepCount > 0 { armFinish() } else { finishTimer?.cancel() }
        return alert
    }

    /// Updates that change what the person must do or know go out at once, ahead of plain progress.
    private static func isCritical(_ state: PokiState, after old: PokiState) -> Bool {
        state.phase != old.phase || state.approval?.id != old.approval?.id || state.decision != old.decision || state.pin != old.pin
    }

    private func armFinish() {
        finishTimer?.cancel()
        let count = state.stepCount
        finishTimer = Task { [weak self, finishAfter] in
            try? await Task.sleep(for: finishAfter)
            guard !Task.isCancelled else { return }
            self?.finishRun(ifCount: count)
        }
    }

    private func finishRun(ifCount count: Int) {
        guard state.phase == .working, state.agentTask?.active != true, state.approval == nil, !inStep, state.stepCount == count, count > 0 else { return }
        state.phase = .done
        runAnnounced = false
        state.endedAt = Date()
        state.headline = "Finished"
        setEvent(.finished, "Finished")
        let summary = state.runSummary
        send(alert: ordinary(String(activity: "Agent finished"), summary), critical: true)
        armFold()
    }

    /// The finished run stays a while, then the activity folds back to Ready: no old run is left
    /// on the Lock Screen.
    private func armFold() {
        foldTimer?.cancel()
        foldTimer = Task { [weak self, foldAfter] in
            try? await Task.sleep(for: foldAfter)
            guard !Task.isCancelled, let self, self.state.phase == .done else { return }
            self.update { state in
                state.phase = .idle
                state.headline = "Waiting for agent"
                state.outcomes = []; state.stepCount = 0; state.failedCount = 0
                state.since = nil; state.endedAt = nil; state.event = nil
                state.agentTask = nil; state.snapshotID = nil; state.snapshotAt = nil; state.thumbnailVersion = 0
            }
        }
    }

    private func setEvent(_ kind: PokiActivityAttributes.Event.Kind, _ text: String) {
        state.event = .init(kind: kind, text: text)
        eventTimer?.cancel()
        let shown = state.event
        eventTimer = Task { [weak self, eventLifetime] in
            try? await Task.sleep(for: eventLifetime)
            guard !Task.isCancelled, let self, self.state.event == shown else { return }
            self.state.event = nil
            self.send(alert: nil, critical: false)
        }
    }

    private func ordinary(_ title: String, _ body: String) -> AlertConfiguration? {
        let now = Date()
        guard now.timeIntervalSince(lastAlert) >= alertSpacing else { return nil }
        lastAlert = now
        return AlertConfiguration(title: "\(title)", body: "\(body)", sound: .default)
    }

    private func critical(_ title: String, _ body: String) -> AlertConfiguration {
        lastAlert = Date()
        return AlertConfiguration(title: "\(title)", body: "\(body)", sound: .default)
    }

    // MARK: Sending

    private func send(alert: AlertConfiguration?, critical: Bool) {
        guard activity != nil else { return }
        if critical || alert != nil {
            // Ahead of any plain progress still waiting, which this state replaces.
            plainWaiting = false
            worker?.cancel(); worker = nil
            budget.spend(at: Self.now())
            enqueue(content(), alert: alert)
            return
        }
        plainWaiting = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            try? await Task.sleep(for: ActivityController.coalescing)
            guard let self, !Task.isCancelled else { return }
            let wait = self.budget.wait(at: Self.now())
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self.worker = nil
            guard self.plainWaiting else { return }
            self.plainWaiting = false
            self.budget.spend(at: Self.now())
            // The newest state, read now: everything since the first wait goes out as one update.
            self.enqueue(self.content(), alert: nil)
        }
    }

    /// Updates go out one after another, so an alert is never overtaken by an older update.
    private func enqueue(_ content: ActivityContent<PokiState>, alert: AlertConfiguration?) {
        guard let activity else { return }
        #if DEBUG && targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "pokiActivityEvidence"),
           let data = try? JSONEncoder().encode(content.state),
           let value = try? JSONSerialization.jsonObject(with: data),
           let entry = try? JSONSerialization.data(withJSONObject: ["at": Date().timeIntervalSince1970, "state": value, "alert": alert != nil]) {
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("activity-evidence.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: entry + Data([10])); try? handle.close()
            }
        }
        #endif
        let previous = tail
        tail = Task {
            await previous?.value
            if let alert { await activity.update(content, alertConfiguration: alert) } else { await activity.update(content) }
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// ActivityKit refuses a state over 4 KB. Ours is far smaller, but long texts from an agent are cut
    /// so an update is never lost to size.
    private func trimToFit() {
        func size() -> Int { (try? JSONEncoder().encode(state).count) ?? 0 }
        guard size() > 3_500 else { return }
        state.headline = String(state.headline.prefix(80))
        if var approval = state.approval {
            approval.summary = String(approval.summary.prefix(80)); approval.reason = String(approval.reason.prefix(60))
            state.approval = approval
        }
    }

    private func content() -> ActivityContent<PokiState> {
        trimToFit()
        // Approvals are urgent; everything else is not. An approval goes stale when it expires.
        // An approval goes stale when it expires. A run goes stale when no update has come for ten
        // minutes (Poki was closed or suspended), and then says it is not updating.
        let stale = state.approval?.expires ?? (state.phase == .working ? Date.now.addingTimeInterval(600) : nil)
        return ActivityContent(state: state, staleDate: stale, relevanceScore: state.approval == nil && state.handoff == nil ? 50 : 100)
    }

    private static func shrink(_ data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// A step from the agent never replaces an approval that is still waiting or being answered: the
/// phase stays until the approval itself ends. (dsh-mobile's AgentLiveActivityUpdatePolicy.)
enum ActivityUpdatePolicy {
    static func settle(_ incoming: inout PokiState, over current: PokiState) {
        guard current.phase.holdsApproval, incoming.phase == .working,
              let approval = incoming.approval, approval.id == current.approval?.id else { return }
        incoming.phase = current.phase
        incoming.decision = current.decision
    }
}

/// The update budget, a token bucket: two updates at once, then one a second. Critical updates
/// spend from it without waiting, so the plain ones after them wait their turn.
/// (esp32-iphone-agent's LiveActivityController rate limit.)
struct UpdateBudget {
    static let perSecond = 1.0
    static let burst = 2.0
    private var tokens = burst
    private var refilled: TimeInterval?

    /// Seconds from `now` until the next update may go out; 0 when one may go now.
    mutating func wait(at now: TimeInterval) -> TimeInterval {
        refill(at: now)
        return tokens >= 1 ? 0 : (1 - tokens) / Self.perSecond
    }

    mutating func spend(at now: TimeInterval) {
        refill(at: now)
        tokens = max(0, tokens - 1)
    }

    private mutating func refill(at now: TimeInterval) {
        if let refilled { tokens = min(Self.burst, tokens + (now - refilled) * Self.perSecond) }
        refilled = now
    }
}
