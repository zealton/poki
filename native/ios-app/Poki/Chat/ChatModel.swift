import Foundation
import PokiCore
import SwiftUI

/// One thing in the conversation, in the order it is drawn.
struct ChatEntry: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        /// "Today 9:41 AM" above a conversation.
        case time(Date)
        case you(String, delivered: Bool)
        case poki(String)
        /// The steps of a task, in one Poki bubble.
        case plan([PlanStep])
        /// One grey line, centred: waiting for, or the result of, an approval.
        case note(ChatNote)
        /// An outside agent's own look or do, as one grey line (`ok` nil while it runs).
        case step(String, ok: Bool?)
        /// An outside agent's request to Poki (`ask_poki`), on the requester's side.
        case request(String, from: String)
    }
    let id: UUID
    var kind: Kind
    var at: Date = Date()
    init(_ kind: Kind) { id = UUID(); self.kind = kind }

    var isPoki: Bool { switch kind { case .poki, .plan: true; default: false } }
}

struct PlanStep: Identifiable, Equatable, Codable {
    enum State: String, Equatable, Codable { case current, waiting, done, failed }
    let id: UUID
    var text: String
    var state: State
    init(_ text: String, state: State = .current) { id = UUID(); self.text = text; self.state = state }
}

enum ChatNote: Equatable, Codable {
    case waiting
    case approved(Date)
    case declined
    case expired
    case problem(String)
    /// The auto-classifier (testing): the chat model is deciding, or decided, with its reason.
    case modelChecking
    case modelApproved(String)
    case modelDeclined(String)
}

/// The chat: the owner's messages, Poki's answers and the steps it takes, and the model loop that runs
/// on this iPhone with the owner's own key (ESP-174). Its prompt and tools are the Mac Poki Agent's
/// (`Harness`): PokiCore's `look` and `do`, with the same approval rules as an agent on a computer, and
/// the agent's `report_plan` and `finish_task`, which drive the plan bubble.
@MainActor
@Observable
final class ChatModel {
    private(set) var entries: [ChatEntry] = [] { didSet { persist() } }
    private(set) var running = false {
        didSet { executionSettings.setRunning(running, task: executionID) }
    }
    /// The model has the turn: nothing from it yet since the owner's message or the last tool answer
    /// (the chat shows the typing bubble).
    private(set) var awaitingModel = false
    /// This conversation in the Sessions list.
    private(set) var sessionID = UUID().uuidString.lowercased()
    /// An in-app chat, or a task an outside agent handed to Poki (`ask_poki`).
    let kind: SavedSession.Kind
    /// The agent that handed the task over, for `.handoff`.
    let requester: String?
    /// The tool calls of this conversation, for "save a routine from this session" (SessionStore.record).
    private(set) var calls: [CallRecord] = []
    /// Told when a task ends, with its calls and finish_task's verdict.
    static var afterTask: (@MainActor (TaskRecord) -> Void)?
    /// A board's sample conversation, for screenshots.
    let isSample = UserDefaults.standard.string(forKey: "pokiChat") != nil
    private let app: AppModel
    /// The model's side of the conversation: pi's loop (ESP-177), or for Anthropic and OpenAI with
    /// `-chatEngine direct`, the provider's own API in its own form.
    private var loop: PiLoop?
    private(set) var containedSafari = false
    private var loopContained = false
    private var loopCarPlay = false
    private var usingCarPlay = false
    private let executionSettings: AgentExecutionSettings
    private let executionID = UUID()
    var carPlay: Bool { executionSettings.backgroundEnabled }
    var canChangeExecutionMode: Bool { executionSettings.canChange }
    var carPlayAvailable: Bool { CarPlayWorkspace.shared.available }
    func setCarPlay(_ enabled: Bool) {
        guard executionSettings.setBackgroundEnabled(enabled) else { return }
        endIsolatedRun()
        containedSafari = false
        // Preserve the transcript while keeping tools/context from the old mode out of the next run.
        loop = nil
        client = nil
    }
    private var usingContained = false
    private var ownsContainedBackground = false
    private var interruption: NSObjectProtocol?

    var containedAvailable: Bool { PKContainedWorkspace.shared().available }
    func setContainedSafari(_ enabled: Bool) {
        guard canChangeExecutionMode, !enabled || containedAvailable else { return }
        if enabled { executionSettings.setBackgroundEnabled(false) }
        newConversation()
        endIsolatedRun()
        containedSafari = enabled
    }
    private func endIsolatedRun() {
        CarPlayWorkspace.shared.stop()
        PKContainedWorkspace.shared().stop()
        if ownsContainedBackground && !app.sessionOn { app.background.stop() }
        ownsContainedBackground = false
    }
    /// For the log's line at the end of each task: when it began, the tool calls, finish_task's verdict.
    private var taskStart = Date()
    private var activityID: UUID?
    private var toolCalls = 0
    private var taskResult: TaskResult?
    private var client: ModelClient?
    /// The plan the model published with report_plan; the bubble shows its steps up to the current one.
    private var modelPlan: [String]?
    private var task: Task<Void, Never>?
    private var stopAsked = false
    /// The plan bubble of the task under way.
    private var planID: UUID?
    private var noteID: UUID?

    /// A task stops after this many model turns: a loop that goes nowhere still ends.
    static let maxTurns = 60

    init(app: AppModel, kind: SavedSession.Kind = .poki, requester: String? = nil, sessionID: String? = nil,
         executionSettings: AgentExecutionSettings = .shared) {
        self.app = app
        self.executionSettings = executionSettings
        if let sessionID { self.sessionID = sessionID }
        self.kind = kind
        self.requester = requester
        #if DEBUG && targetEnvironment(simulator)
        // Preserve the explicit LiveContainer lab launcher, not stale development defaults.
        if ProcessInfo.processInfo.arguments.contains("-pokiContainedSafari"),
           UserDefaults.standard.bool(forKey: "pokiContainedSafari"), PKContainedWorkspace.shared().available {
            executionSettings.setBackgroundEnabled(false)
            containedSafari = true
        }
        #endif
        interruption = NotificationCenter.default.addObserver(forName: NSNotification.Name("PokiContainedUserInterruption"), object:nil, queue:.main) { [weak self] _ in
            Task { @MainActor in if self?.usingContained == true { self?.stop() } }
        }
        app.addShellObserver { [weak self] event in self?.observe(event) }
        if kind == .handoff { return }
        // A live voice conversation is part of this chat: what was said and done stays in its history.
        if requester == nil { app.voice.onConversationEnded = { [weak self] lines, started in self?.appendVoice(lines, started: started) } }
        if let scene = UserDefaults.standard.string(forKey: "pokiChat") { loadSample(scene); return }
        // The last in-app conversation comes back at launch, as in Messages.
        if let last = SessionStore.shared.latestPoki(), Date().timeIntervalSince(last.updated) < 12 * 3600 {
            restore(last)
        } else {
            greet()
        }
    }

    private var greeting: [ChatEntry] {
        [ChatEntry(.time(Date())),
         ChatEntry(.poki(String(localized: "Hi, I’m Poki. Tell me what to do on this iPhone."))),
         ChatEntry(.poki(String(localized: "I’ll ask before anything you can’t undo.")))]
    }

    private func greet() { entries = greeting }

    /// A live voice conversation that just ended, into this chat's history (and its saved session).
    func appendVoice(_ lines: [VoiceLine], started: Date) {
        entries.append(contentsOf: SessionStore.entries(voice: lines, started: started))
    }

    func newConversation() {
        stop()
        loop = nil
        client = nil
        calls = []
        planID = nil; noteID = nil; modelPlan = nil
        sessionID = UUID().uuidString.lowercased()
        greet()
    }

    /// Opens a saved in-app conversation again. The words come back; the model starts with what is on
    /// screen as context only from the next message on (pi's messages are not kept on disk).
    func restore(_ session: SavedSession) {
        guard session.kind == .poki, !running else { return }
        loop = nil
        client = nil
        planID = nil; noteID = nil; modelPlan = nil
        sessionID = session.id
        calls = session.calls
        entries = session.entries.isEmpty ? greeting : session.entries
    }

    /// The conversation as the Sessions list keeps it. Greeting-only conversations are not saved.
    private func persist() {
        guard !isSample, entries.contains(where: { if case .you = $0.kind { return true }; if case .request = $0.kind { return true }; return false }) else { return }
        SessionStore.shared.save(chat: self)
    }

    var savedCalls: [CallRecord] { calls }

    /// The first thing asked, for the Sessions row.
    var title: String {
        for entry in entries {
            switch entry.kind {
            case .you(let text, _), .request(let text, _): return text
            default: continue
            }
        }
        return String(localized: "New conversation")
    }

    // MARK: Sending

    func send(_ text: String) { send(text, again: false) }

    /// The last message again, after a problem (the Retry button under it).
    func retry() {
        guard !running, let last = entries.last(where: { if case .you = $0.kind { return true }; return false }), case .you(let text, _) = last.kind else { return }
        while let tail = entries.last, case .note(.problem) = tail.kind { entries.removeLast() }
        send(text, again: true)
    }

    /// The conversation ended on a problem the owner can try again.
    var canRetry: Bool {
        guard !running, let tail = entries.last, case .note(.problem) = tail.kind else { return false }
        return entries.contains { if case .you = $0.kind { return true }; return false }
    }

    private var lastOwnerText: String?

    /// What was said in this chat, oldest first, for the auto-classifier.
    var ownerContext: [String] {
        entries.suffix(30).compactMap { entry in
            switch entry.kind {
            case .you(let text, _): "Owner: \(text)"
            case .request(let text, let from): "Request from \(from): \(text)"
            case .poki(let text): "Assistant: \(String(text.prefix(400)))"
            default: nil
            }
        }
    }

    private func send(_ text: String, again: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        // Another conversation (an outside agent's hand-off) is working the phone: one task at a time.
        if kind == .poki, let busy = ChatModel.delegatedBusy {
            entries.append(ChatEntry(.you(text, delivered: false)))
            add(.note(.problem(String(localized: "Poki is working on a task for \(busy). Try again when it’s done."))))
            return
        }
        // A pause of half an hour or more gets its own time line, as in Messages.
        if !again, let lastAt = entries.last?.at, Date().timeIntervalSince(lastAt) > 1800 { entries.append(ChatEntry(.time(Date()))) }
        let you: ChatEntry
        if again, let last = entries.last(where: { if case .you = $0.kind { return true }; return false }) {
            you = last
        } else {
            you = ChatEntry(kind == .handoff ? .request(text, from: requester ?? "") : .you(text, delivered: false))
            entries.append(you)
        }
        lastOwnerText = text
        if kind == .poki { Haptics.sent() }
        usingCarPlay = carPlay
        usingContained = containedSafari && !carPlay
        if usingCarPlay && !carPlayAvailable {
            add(.note(.problem(String(localized: "Background execution is not available here yet. Turn this off to use Poki’s original mode."))))
            return
        }
        let provider = ModelKeys.selectedProvider
        guard provider.wired, let key = ModelKeys.key(provider) ?? (provider == .custom && ModelKeys.hasUsableKey ? "none" : nil) else {
            add(.poki(provider.signsIn ? String(localized: "Sign in to ChatGPT first: tap my picture, then Model.")
                                       : String(localized: "Add a model key first: tap my picture, then Model.")))
            return
        }
        let model = ModelKeys.selectedModel
        // The first message names the chat: a few words from the chat's own model, in the background.
        if kind == .poki, !again, entries.filter({ if case .you = $0.kind { return true }; return false }).count == 1,
           let piModel = provider.piModel(model) {
            let id = sessionID
            Task { if let name = await SessionNamer.name(for: text, provider: provider, model: piModel) { SessionStore.shared.setAutoName(id, name) } }
        }
        if usingCarPlay {
            CarPlayWorkspace.shared.begin()
        }
        if usingContained || usingCarPlay {
            guard !usingContained || containedAvailable else { add(.note(.problem("Safari container unavailable."))); return }
            ownsContainedBackground = !app.background.isOn
            if ownsContainedBackground { app.background.start() }
        }
        running = true
        awaitingModel = true
        stopAsked = false
        planID = nil; noteID = nil; modelPlan = nil
        let instructions = usingCarPlay ? CarPlayHarness.instructions : (usingContained ? ContainedHarness.instructions : Harness.instructions(for: text))
        if !usingContained && !usingCarPlay && Self.direct && (provider == .anthropic || provider == .openai) {
            // Another model starts a new conversation on the model's side; the chat on screen stays.
            if client?.signature != "\(provider.rawValue)/\(model)" {
                client = provider == .openai ? OpenAIClient(key: key, model: model) : AnthropicClient(key: key, model: model)
            }
            guard let client else { return }
            client.say(text)
            began("direct", provider, model)
            task = Task { [weak self] in
                await self?.run(client, instructions: instructions, delivered: you.id)
                self?.logEnd("direct", outcome: nil)
                self?.running = false
                self?.awaitingModel = false
            }
            return
        }
        guard let piModel = provider.piModel(model) else {
            if usingContained || usingCarPlay { endIsolatedRun() }
            running = false
            add(.note(.problem(String(localized: "pi has no model \(model) for \(provider.name)."))))
            return
        }
        // Another model starts a new loop that carries the conversation over.
        if loop?.provider != provider || loop?.model.id != piModel.id || loopContained != usingContained || loopCarPlay != usingCarPlay {
            let carry = loopContained == usingContained && loopCarPlay == usingCarPlay ? (loop?.messages ?? []) : []
            loopContained = usingContained
            loopCarPlay = usingCarPlay
            loop = PiLoop(provider: provider, model: piModel, tools: usingCarPlay ? CarPlayHarness.tools : (usingContained ? ContainedHarness.tools : Harness.tools),
                          carrying: carry) { [weak self] call in
                guard let self else { return PokiCore.ToolAnswer(text: "Task stopped. Action not executed.", jpeg: nil, isError: true) }
                return await self.perform(call)
            }
        }
        guard let loop else { return }
        began("pi", provider, model)
        task = Task { [weak self] in
            let outcome = await loop.run(text, instructions: instructions, maxTurns: Self.maxTurns) { text in
                self?.markDelivered(you.id)
                self?.awaitingModel = false
                self?.add(.poki(text))
            }
            self?.ended(outcome, delivered: you.id)
            self?.logEnd("pi", outcome: outcome)
            self?.running = false
            self?.awaitingModel = false
            self?.lastOutcome = outcome
        }
    }

    /// Every provider runs on pi. `-chatEngine direct` sends Anthropic and OpenAI through their own APIs
    /// instead; that code goes once the phone acceptance with the owner's OpenAI key has passed on pi.
    private static var direct: Bool { UserDefaults.standard.string(forKey: "chatEngine") == "direct" }

    private func began(_ engine: String, _ provider: ModelProvider, _ model: String) {
        taskStart = Date(); toolCalls = 0; taskResult = nil
        let id = UUID(); activityID = id
        app.beginAgentActivity(id, background: usingCarPlay || usingContained) { [weak self] in self?.stop() }
        AppLog.shared.add("chat", "task started: \(engine), \(provider.rawValue)/\(model)")
    }

    private func logEnd(_ engine: String, outcome: PiLoop.Outcome?) {
        finishActivity(outcome)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(taskStart))
        let verdict = taskResult.map { $0.success ? "success" : "failure" } ?? "not called"
        let ending = outcome.map { if case .failed = $0 { "failed" } else { "\($0)" } } ?? (stopAsked ? "stopped" : "ended")
        AppLog.shared.add("chat", "task ended: \(engine), \(ending) after \(seconds) s, \(toolCalls) tool calls, finish_task \(verdict)")
        let record = TaskRecord(session: sessionID, task: lastOwnerText ?? "", calls: Array(calls.suffix(toolCalls)), result: taskResult,
                                seconds: Date().timeIntervalSince(taskStart))
        Self.afterTask?(record)
        SessionStore.shared.taskEnded(sessionID, success: taskResult?.success, stopped: stopAsked)
        if kind == .poki, taskResult?.success == true { Haptics.done() }
    }

    private var lastOutcome: PiLoop.Outcome?

    /// Runs a task an outside agent handed over (`ask_poki`) and answers with Poki's last words, how the
    /// task ended, and finish_task's summary and answer.
    func runDelegated(_ task: String) async -> (text: String, success: Bool?) {
        ChatModel.delegatedBusy = requester ?? String(localized: "an agent")
        defer { ChatModel.delegatedBusy = nil }
        lastOutcome = nil
        send(task)
        while running { try? await Task.sleep(for: .milliseconds(100)) }
        let replies = entries.compactMap { entry -> String? in if case .poki(let text) = entry.kind { return text }; return nil }
        var lines: [String] = []
        if let taskResult {
            lines.append("result: \(taskResult.success ? "done" : "not done"): \(taskResult.summary)")
            if let answer = taskResult.answerLine { lines.append(answer) }
        }
        if let last = replies.last { lines.append("Poki said: \(last)") }
        if case .failed(let why)? = lastOutcome { lines.append("error: \(why)") }
        if lastOutcome == nil, let tail = entries.last, case .note(.problem(let why)) = tail.kind { lines.append("error: \(why)") }
        if lines.isEmpty { lines.append("Poki ended without an answer.") }
        return (lines.joined(separator: "\n"), taskResult?.success)
    }

    /// The display name of the agent whose hand-off is running, while one runs.
    static var delegatedBusy: String?

    private func ended(_ outcome: PiLoop.Outcome, delivered youID: UUID) {
        finishPlan()
        finishActivity(outcome)
        // The turn is over: the phone goes back to the app the task began in (Poki's chat, where the
        // reply is), as a client's finish does (ESP-176). Nothing moves when it is in front already.
        if usingContained || usingCarPlay { endIsolatedRun() } else { app.finishTask() }
        switch outcome {
        case .done: markDelivered(youID)
        case .stopped: add(.poki(String(localized: "Stopped.")))
        case .overTurns: add(.poki(String(localized: "I stopped after \(Self.maxTurns) steps. Tell me how to go on.")))
        case .failed(let words): add(.note(.problem(words)))
        }
    }

    /// Ends the task after the step under way: nothing more is sent to the phone or the model.
    func stop() {
        if let id = activityID { app.endAgentActivity(id, success: nil, stopped: true) }
        if usingContained || usingCarPlay { endIsolatedRun() }
        guard running else { return }
        stopAsked = true
        loop?.stop()
        task?.cancel()
    }

    private func run(_ client: ModelClient, instructions: String, delivered youID: UUID) async {
        for _ in 0..<Self.maxTurns {
            let turn: ModelTurn
            do {
                turn = try await client.next(instructions: instructions, tools: Harness.tools)
            } catch {
                client.forgetUnansweredQuestion()
                if stopAsked || Task.isCancelled { return }
                add(.note(.problem(error.localizedDescription)))
                return
            }
            markDelivered(youID)
            for text in turn.texts { add(.poki(text)) }
            switch turn.ending {
            case .tools:
                for call in turn.calls {
                    if stopAsked || Task.isCancelled {
                        client.answer(call, PokiCore.ToolAnswer(text: "Task stopped. Action not executed.", jpeg: nil, isError: true))
                        continue
                    }
                    client.answer(call, await perform(call))
                }
                if stopAsked || Task.isCancelled { finishPlan(); add(.poki(String(localized: "Stopped."))); return }
            case .again:
                continue
            case .refused:
                finishPlan()
                add(.poki(String(localized: "The model declined this request.")))
                return
            case .cutOff:
                finishPlan()
                add(.note(.problem(String(localized: "The answer was cut off."))))
                return
            case .done:
                // A reply without tools ends the turn, as a chat does: the model may be asking the owner something.
                finishPlan()
                return
            }
        }
        finishPlan()
        add(.poki(String(localized: "I stopped after \(Self.maxTurns) steps. Tell me how to go on.")))
    }

    /// The phone's tools go to PokiCore; the harness's two are answered here, as task-runner.mjs answers them.
    private func perform(_ call: ToolCall) async -> PokiCore.ToolAnswer {
        awaitingModel = false
        let started = Date()
        let id = activityID
        let title = isolatedActivityTitle(call)
        if let id, let title { app.isolatedActivityStarted(id, title: title, app: isolatedAppName) }
        let answer = await performCall(call)
        if let id, let title, !stopAsked, !Task.isCancelled {
            app.isolatedActivityFinished(id, title: title, app: isolatedAppName, answer: answer)
        }
        calls.append(CallRecord(name: call.name, arguments: call.arguments, answer: String(answer.text.prefix(2000)), ms: Int(Date().timeIntervalSince(started) * 1000), ok: !answer.isError))
        if !stopAsked { awaitingModel = true }
        persist()
        return answer
    }

    private func performCall(_ call: ToolCall) async -> PokiCore.ToolAnswer {
        toolCalls += 1
        let args = (call.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        if usingCarPlay {
            guard !stopAsked, !Task.isCancelled else { return PokiCore.ToolAnswer(text:"Task stopped.", jpeg:nil, isError:true) }
            switch call.name {
            case "carplay_apps": return CarPlayWorkspace.shared.listApps()
            case "carplay_open": return await CarPlayWorkspace.shared.open(args["bundle"] as? String ?? "")
            case "carplay_look": return await CarPlayWorkspace.shared.look()
            case "carplay_press", "carplay_tap", "carplay_type":
                var input = args
                input["action"] = call.name == "carplay_type" ? "text" : "tap"
                return await CarPlayWorkspace.shared.perform(input)
            case "carplay_do": return await CarPlayWorkspace.shared.perform(args)
            case "report_plan", "finish_task": break
            default: return PokiCore.ToolAnswer(text:"Tool unavailable in CarPlay mode. No foreground fallback.", jpeg:nil, isError:true)
            }
        }
        if usingContained {
            guard !stopAsked, !Task.isCancelled else { return PokiCore.ToolAnswer(text:"Task stopped.", jpeg:nil, isError:true) }
            switch call.name {
            case "container_look": return await ContainedHarness.look()
            case "container_do": return await ContainedHarness.perform(args)
            case "report_plan", "finish_task": break
            default: return PokiCore.ToolAnswer(text:"Tool unavailable in isolated Safari mode. No foreground fallback.", jpeg:nil, isError:true)
            }
        }
        switch call.name {
        case "report_plan":
            guard let steps = args["steps"] as? [String], (1...8).contains(steps.count), let current = args["currentStep"] as? Int, (1...steps.count).contains(current) else {
                return PokiCore.ToolAnswer(text: Harness.invalidPlan, jpeg: nil, isError: true)
            }
            showPlan(steps, current: current)
            return PokiCore.ToolAnswer(text: Harness.planPublished, jpeg: nil, isError: false)
        case "finish_task":
            guard let result = try? JSONDecoder().decode(TaskResult.self, from: Data(call.arguments.utf8)) else {
                return PokiCore.ToolAnswer(text: Harness.invalidResult, jpeg: nil, isError: true)
            }
            taskResult = result
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .current || steps[i].state == .waiting { steps[i].state = result.success ? .done : .failed }
            }
            return PokiCore.ToolAnswer(text: Harness.resultRecorded, jpeg: nil, isError: false)
        default:
            return await app.runTool(call.name, arguments: call.arguments)
        }
    }

    /// The bubble shows the model's steps up to the current one: those before it done, it under way. A step
    /// appears when the model reaches it, as the board draws them.
    private func showPlan(_ plan: [String], current: Int) {
        if let id = activityID { app.agentActivityPlan(id, steps: plan, current: current) }
        modelPlan = plan
        updatePlan { steps in
            if steps.count > current { steps.removeLast(steps.count - current) }
            for i in 0..<current {
                let state: PlanStep.State = i < current - 1 ? .done : (steps.indices.contains(i) && steps[i].state == .waiting ? .waiting : .current)
                if steps.indices.contains(i) { steps[i].text = plan[i]; steps[i].state = state } else { steps.append(PlanStep(plan[i], state: state)) }
            }
        }
    }

    private var isolatedAppName: String? { usingCarPlay ? CarPlayWorkspace.shared.selectedAppName : (usingContained ? "Safari" : nil) }

    /// Operation names only: typed values and raw tool arguments never reach the Lock Screen.
    private func isolatedActivityTitle(_ call: ToolCall) -> String? {
        guard usingCarPlay && call.name.hasPrefix("carplay_") || usingContained && call.name.hasPrefix("container_") else { return nil }
        switch call.name {
        case "carplay_apps": return String(activity: "Finding apps")
        case "carplay_open": return String(activity: "Opening app")
        case "carplay_look", "container_look": return String(activity: "Reading screen")
        case "carplay_press", "carplay_tap": return String(activity: "Tapping a button")
        case "carplay_type": return String(activity: "Entering text")
        default:
            let args = (call.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
            return args?["action"] as? String == "wait" ? String(activity: "Waiting for screen") : String(activity: "Scrolling")
        }
    }

    private func finishActivity(_ outcome: PiLoop.Outcome?) {
        guard let id = activityID else { return }
        let failed: Bool
        switch outcome { case .failed?, .overTurns?: failed = true; default: failed = false }
        app.endAgentActivity(id, success: failed ? false : taskResult?.success, stopped: stopAsked || outcome == .stopped)
    }

    // MARK: Steps and approvals from PokiCore

    private func observe(_ event: ShellEvent) {
        guard running else { return }
        switch event {
        case .toolStarted(let name, let summary, let session):
            guard session == nil else { return }
            guard name == "do", modelPlan == nil else { return }
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .current { steps[i].state = .done }
                steps.append(PlanStep(ActivityWords.label(summary)))
            }
        case .toolFinished(let summary, let delivery, _, _, _, let session):
            guard session == nil, summary != "Look at the screen", modelPlan == nil else { return }
            let failed = delivery.hasPrefix("failed")
            let waiting = delivery.contains("approval_required")
            updatePlan { steps in
                guard let i = steps.lastIndex(where: { $0.state == .current || $0.state == .waiting }) else { return }
                steps[i].state = failed ? .failed : waiting ? .current : .done
            }
        case .approvalRequested(let approval):
            updatePlan { steps in
                if let i = steps.lastIndex(where: { $0.state == .current }) {
                    steps[i].state = .waiting
                } else {
                    steps.append(PlanStep(approval.summary, state: .waiting))
                }
            }
            setNote(ApprovalClassifier.isOn ? .modelChecking : .waiting)
        case .approvalEnded(let id, let approved) where ApprovalClassifier.isOn:
            let why = ApprovalClassifier.verdicts[id]?.reason ?? ""
            setNote(approved == true ? .modelApproved(why) : .modelDeclined(why))
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .waiting { steps[i].state = approved == true ? .current : .failed }
            }
        case .approvalEnded(_, let approved):
            switch approved {
            case true?: setNote(.approved(Date()))
            case false?: setNote(.declined)
            case nil: setNote(.expired)
            }
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .waiting { steps[i].state = approved == true ? .current : .failed }
            }
        // The agent handed a screen to the person (a passcode, a payment): the current step waits for
        // them, as for an approval, until they tap Done on the Live Activity.
        case .handoffRequested:
            updatePlan { steps in
                if let i = steps.lastIndex(where: { $0.state == .current }) { steps[i].state = .waiting }
            }
        case .handoffEnded:
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .waiting { steps[i].state = .current }
            }
        case .relay, .session: break
        }
    }

    private func updatePlan(_ change: (inout [PlanStep]) -> Void) {
        if let id = planID, let i = entries.firstIndex(where: { $0.id == id }), case .plan(var steps) = entries[i].kind {
            change(&steps)
            entries[i].kind = .plan(steps)
            return
        }
        var steps: [PlanStep] = []
        change(&steps)
        guard !steps.isEmpty else { return }
        let entry = ChatEntry(.plan(steps))
        planID = entry.id
        entries.append(entry)
    }

    /// The task ended: a step still marked current was the last one done.
    private func finishPlan() {
        updatePlan { steps in for i in steps.indices where steps[i].state == .current { steps[i].state = .done } }
    }

    private func setNote(_ note: ChatNote) {
        if let id = noteID, let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].kind = .note(note)
        } else {
            let entry = ChatEntry(.note(note))
            noteID = entry.id
            entries.append(entry)
        }
    }

    private func add(_ kind: ChatEntry.Kind) {
        if case .poki = kind, self.kind == .poki, running { Haptics.received() }
        entries.append(ChatEntry(kind))
    }

    private func markDelivered(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), case .you(let text, false) = entries[i].kind else { return }
        entries[i].kind = .you(text, delivered: true)
    }

    // MARK: Screenshots

    /// `-pokiChat empty|working|approved`: the ESP-171 boards' conversations, for the build's
    /// screenshots only. Nothing is sent.
    private func loadSample(_ scene: String) {
        let start = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
        entries = greeting
        entries[0] = ChatEntry(.time(start))
        guard scene != "empty" else { return }
        let you = String(localized: "Text Mom “On my way”")
        if scene == "working" {
            entries = [ChatEntry(.time(start)),
                       ChatEntry(.poki(String(localized: "Hi, I’m Poki. Tell me what to do on this iPhone."))),
                       ChatEntry(.you(you, delivered: true)),
                       ChatEntry(.poki(String(localized: "On it. Opening Messages."))),
                       ChatEntry(.plan([PlanStep(String(localized: "Open Messages"), state: .done),
                                        PlanStep(String(localized: "Open the chat with Mom"), state: .done),
                                        PlanStep(String(localized: "Type “On my way”"), state: .done),
                                        PlanStep(String(localized: "Tap Send"), state: .waiting)])),
                       ChatEntry(.note(.waiting))]
        } else {
            entries = [ChatEntry(.time(start)),
                       ChatEntry(.you(you, delivered: true)),
                       ChatEntry(.plan([PlanStep(String(localized: "Open Messages"), state: .done),
                                        PlanStep(String(localized: "Open the chat with Mom"), state: .done),
                                        PlanStep(String(localized: "Type “On my way”"), state: .done),
                                        PlanStep(String(localized: "Tap Send"), state: .done)])),
                       ChatEntry(.note(.approved(start.addingTimeInterval(60)))),
                       ChatEntry(.poki(String(localized: "Sent. Mom has it. Anything else?")))]
        }
    }
}


/// One tool call of a conversation, without its picture.
struct CallRecord: Codable, Equatable {
    var name: String
    var arguments: String
    var answer: String
    var ms: Int
    var ok: Bool
}

/// A finished task, for memory and routines.
struct TaskRecord {
    var session: String
    var task: String
    var calls: [CallRecord]
    /// What finish_task said; nil when the model never called it.
    var result: TaskResult?
    var seconds: Double
}

/// finish_task's arguments: the verdict, the summary, the requested facts, and the answer's kind with
/// the screen elements it read them from.
struct TaskResult: Decodable, Equatable {
    struct Detail: Decodable, Equatable {
        var label: String
        var value: String
    }
    struct Answer: Decodable, Equatable {
        enum Kind: String, Decodable { case action, field, list }
        struct Item: Decodable, Equatable {
            var ref: String
            var field: String
            var prefix: String?
            var suffix: String?
        }
        var kind: Kind
        var items: [Item]?
        var startRef: String?
        var endRef: String?
        enum CodingKeys: String, CodingKey { case kind, items, startRef = "start_ref", endRef = "end_ref" }
    }
    var success: Bool
    var summary: String
    var details: [Detail]
    var answer: Answer?

    private enum CodingKeys: String, CodingKey { case success, summary, details, answer }

    /// success and summary are required, as task-runner.mjs requires them; details and answer are kept
    /// when they are well formed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decode(Bool.self, forKey: .success)
        summary = try c.decode(String.self, forKey: .summary)
        details = (try? c.decodeIfPresent([Detail].self, forKey: .details)) ?? []
        answer = (try? c.decodeIfPresent(Answer.self, forKey: .answer)) ?? nil
    }

    /// The requested facts for whoever handed the task over, such as "answer (field): Battery: 81%".
    var answerLine: String? {
        let facts = details.map { "\($0.label): \($0.value)" }.joined(separator: "; ")
        guard let kind = answer?.kind else { return facts.isEmpty ? nil : "details: \(facts)" }
        return "answer (\(kind.rawValue))" + (facts.isEmpty ? "" : ": \(facts)")
    }
}

/// Light taps for the chat, as Messages gives them.
@MainActor
enum Haptics {
    static func sent() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func received() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6) }
    static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
