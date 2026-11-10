import PokiCore
import SwiftUI
import UIKit

/// The Debug tab's check of UI automation from Poki's own process (no runner, no port): open the
/// daemon session, tap, type. Every step goes to Poki's log, to the system log (`PokiInProcess`), and
/// to Documents/inprocess-probe.json.
///
/// Launch arguments run it without touching the phone, for a device check from the Mac:
/// `-pokiInProcess self` taps the field below and types into it, then reads it back;
/// `-pokiInProcess later -pokiProbeX 200 -pokiProbeY 300 -pokiProbeDelay 8` waits, then taps that
/// point and types, whatever app is in front by then;
/// `-automationPath runner -pokiInProcess source -pokiProbeDelay 10` waits, then keeps the front app's
/// tree as read by Poki Runner and by Poki's own process;
/// `-pokiInProcess apps -pokiProbeApp BUNDLE` launches that app, launches Settings, activates the app,
/// launches it again and terminates it, noting the front app and its pid after each;
/// `-pokiInProcess tools -pokiProbeApp BUNDLE` runs PokiCore's look and do as an agent would: open
/// the app, tap its first field and type, open Settings and swipe, press Home, looking after each;
/// `-pokiInProcess gym` runs the whole Poki Gym scorecard (native/ios-gym/check) through PokiCore on
/// this path, answering approvals as the owner would, into Documents/gym-scorecard.txt and
/// Documents/gym-pictures (the gym workflow's scorecard-inprocess job).
@MainActor
final class InProcessProbe: ObservableObject {
    static let shared = InProcessProbe()
    static let sample = "poki123 AbC 中文24680"

    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false
    @Published var x = "201"
    @Published var y = "437"
    @Published var delay = "8"
    weak var field: UITextField?

    static func isChineseInputLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        let tag = language.lowercased().replacingOccurrences(of: "_", with: "-")
        return tag == "zh" || tag.hasPrefix("zh-")
    }

    /// This evidence is valid only for our focused diagnostics field, never
    /// inferred from the installed keyboards or reused for another app.
    var focusedInputLanguage: String? {
        guard UIApplication.shared.applicationState == .active,
              let field, field.isFirstResponder else { return nil }
        return field.textInputMode?.primaryLanguage
    }

    let queue = DispatchQueue(label: "poki.inprocess.probe", qos: .userInitiated)
    private var record: [[String: Any]] = []
    #if DEBUG && targetEnvironment(simulator)
    private var interactiveGrant: UIBackgroundTaskIdentifier = .invalid
    private func endInteractiveGrant() {
        guard interactiveGrant != .invalid else { return }
        UIApplication.shared.endBackgroundTask(interactiveGrant)
        interactiveGrant = .invalid
    }
    #endif

    func startFromLaunchArguments(model: AppModel) {
        let defaults = UserDefaults.standard
        guard let mode = defaults.string(forKey: "pokiInProcess") else { return }
        if let v = defaults.string(forKey: "pokiProbeX") { x = v }
        if let v = defaults.string(forKey: "pokiProbeY") { y = v }
        if let v = defaults.string(forKey: "pokiProbeDelay") { delay = v }
        Task {
            // The field has to be on screen for the self test.
            try? await Task.sleep(for: .seconds(1.5))
            switch mode {
            case "self": await selfTest()
            case "later": await later()
            case "read": await readOnly()
            case "separate": await separateTrial()
            case "port": await portCheck()
            case "source": await sourceBothPaths(model: model)
            case "apps": await appsCycle(defaults.string(forKey: "pokiProbeApp") ?? "local.pokimcp.fixture")
            case "tools": await toolsCycle(model: model, app: defaults.string(forKey: "pokiProbeApp") ?? "local.pokimcp.fixture")
            case "gym": await gymScorecard(model: model)
            case "chat": await chatCycle(model: model)
            case "chat-openrouter": await chatCycle(model: model, liveOpenRouter: true)
            #if DEBUG && targetEnvironment(simulator)
            case "interactive":
                // Simulator-only setup for testing the normal chat UI. The phone tools and model
                // remain Poki's production implementations; there is no scripted task or reply.
                if await prepare() {
                    model.inProcessReadyForProbe()
                    endInteractiveGrant()
                    interactiveGrant = UIApplication.shared.beginBackgroundTask(withName: "Poki Simulator acceptance") { [weak self] in
                        Task { @MainActor in self?.endInteractiveGrant() }
                    }
                }
            #endif
            case "bench": await benchmark(rounds: defaults.integer(forKey: "pokiBenchRounds") > 0 ? defaults.integer(forKey: "pokiBenchRounds") : 5)
            default: await prepareOnly()
            }
        }
    }

    func prepareOnly() async {
        guard begin("prepare") else { return }
        _ = await prepare()
        end()
    }

    func readOnly() async {
        guard begin("read") else { return }
        defer { end() }
        guard await prepare() else { return }
        await read()
    }

    private func read() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().readProbe()) }
        }
        let parts = result.keys.sorted().map { "\($0)=\(result[$0]!)" }.joined(separator: " ")
        note("read: \(parts)", result.merging(["step": "read"]) { a, _ in a })
    }

    /// Taps Poki's own empty field, which focuses it only if the tap arrived, types the sample and
    /// reads the field back.
    func selfTest() async {
        guard begin("self test") else { return }
        defer { end() }
        guard await prepare(), let field else { return }
        field.text = ""
        field.resignFirstResponder()
        try? await Task.sleep(for: .seconds(0.4))
        let frame = field.convert(field.bounds, to: nil)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let pasteboard = UIPasteboard.general.changeCount
        let tap = await touch([[PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.05)]], "tap at [\(Int(point.x)), \(Int(point.y))]")
        try? await Task.sleep(for: .seconds(0.6))
        note("tap landed: field focused = \(field.isFirstResponder)", ["step": "tap_check", "focused": field.isFirstResponder])
        guard tap.delivery == .sent else { return }
        let typed = await type(Self.sample)
        try? await Task.sleep(for: .seconds(0.6))
        let value = field.text ?? ""
        let same = value == Self.sample
        note("read back: \(same ? "same as sent" : "differs (\(value.count) characters)"); clipboard \(UIPasteboard.general.changeCount == pasteboard ? "unchanged" : "changed")",
             ["step": "read_back", "same": same, "characters": value.count, "clipboard_unchanged": UIPasteboard.general.changeCount == pasteboard, "type_delivery": typed.delivery.rawValue])
    }

    /// For another app in front: waits, then taps the point (or, with x "field", the first text or
    /// search field in the front app's tree) and types the sample there, then reads the focused
    /// field back through the in-process tree.
    func later() async {
        guard begin("tap and type later") else { return }
        defer { end() }
        guard await prepare() else { return }
        let seconds = Double(delay) ?? 8
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        note("waiting \(Int(seconds)) s; bring the app to try to the front", ["step": "wait", "seconds": seconds])
        try? await Task.sleep(for: .seconds(seconds))
        note("app state: \(UIApplication.shared.applicationState == .active ? "Poki in front" : "Poki in the background")", ["step": "state", "active": UIApplication.shared.applicationState == .active])
        var point = CGPoint(x: Double(x) ?? 201, y: Double(y) ?? 437)
        if x == "field" {
            guard let found = await frontField() else { note("no text or search field in the front app's tree", ["step": "field_missing"]); return }
            point = found
        }
        let tap = await touch([[PKTouchPoint.at(point, offset: 0), PKTouchPoint.at(point, offset: 0.05)]], "tap at [\(Int(point.x)), \(Int(point.y))]")
        guard tap.delivery == .sent else { return }
        try? await Task.sleep(for: .seconds(1.0))
        _ = await type(Self.sample)
        try? await Task.sleep(for: .seconds(0.8))
        let value = await focusedValue()
        // A field that already held text (a fixture app kept running since an earlier check) ends with
        // the sample instead of equalling it.
        let appended = value.map { $0 != Self.sample && $0.hasSuffix(Self.sample) } ?? false
        note("read back in the front app: \(value == Self.sample ? "same as sent" : appended ? "sent text appended to what the field held" : value.map { "differs (\($0.count) characters)" } ?? "no focused field")",
             ["step": "read_back_front", "same": value == Self.sample, "appended": appended, "focused": value != nil, "characters": value?.count ?? 0])
        await read()
    }

    func appsCycle(_ bundle: String) async {
        guard begin("open, switch and close \(bundle)") else { return }
        defer { end() }
        guard await prepare() else { return }
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        for (action, target) in [("launch", bundle), ("launch", "com.apple.Preferences"), ("activate", bundle), ("launch", bundle), ("terminate", bundle)] {
            let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
                queue.async {
                    let t = ProcessInfo.processInfo.systemUptime
                    let code = PKInProcess.shared().app(target, action: action)
                    Thread.sleep(forTimeInterval: 1)
                    let front = PKInProcess.shared().frontApp()
                    c.resume(returning: ["code": code ?? "", "seconds": ProcessInfo.processInfo.systemUptime - t,
                                         "front": front["bundleId"] as? String ?? "", "front_pid": front["pid"] as? Int ?? 0])
                }
            }
            note("\(action) \(target): \((result["code"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "done"), front \(result["front"] ?? "?") pid \(result["front_pid"] ?? 0)",
                 result.merging(["step": "app", "action": action, "bundle": target]) { a, _ in a })
        }
    }

    func toolsCycle(model: AppModel, app bundle: String) async {
        guard begin("look and do through PokiCore") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        let background = UIApplication.shared.beginBackgroundTask(withName: "In-process probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        func call(_ label: String, _ name: String, _ arguments: String) async -> String {
            let t = ProcessInfo.processInfo.systemUptime
            let result = await model.phoneTool(name, arguments: arguments)
            let head = result.text.split(separator: "\n").prefix(3).joined(separator: " | ")
            note("\(label): \(result.isError ? "failed" : "ok") \(head.prefix(200))",
                 ["step": "tool", "label": label, "tool": name, "error": result.isError, "seconds": ProcessInfo.processInfo.systemUptime - t, "text": String(result.text.prefix(4000))])
            return result.text
        }
        _ = await call("look first", "look", "{}")
        _ = await call("open the app", "do", "{\"actions\":[{\"launch\":\"\(bundle)\"}]}")
        if let field = await frontField() {
            _ = await call("tap the field and type", "do", "{\"actions\":[{\"tap\":[\(Int(field.x)),\(Int(field.y))]},{\"type\":\"\(Self.sample)\"}]}")
        } else {
            note("no field in the app's tree", ["step": "field_missing"])
        }
        let typed = await call("look after typing", "look", "{}")
        note("the typed text \(typed.contains(Self.sample) ? "is" : "is not") on the screen", ["step": "typed_seen", "seen": typed.contains(Self.sample)])
        _ = await call("open Settings", "do", "{\"actions\":[{\"launch\":\"com.apple.Preferences\"}]}")
        let before = await call("look before the swipe", "look", "{}")
        _ = await call("swipe up", "do", "{\"actions\":[{\"swipe\":\"up\"}]}")
        let after = await call("look after the swipe", "look", "{}")
        note("the swipe \(before == after ? "did not change" : "changed") the screen", ["step": "swipe_seen", "changed": before != after])
        _ = await call("press Home", "do", "{\"actions\":[{\"button\":\"home\"}]}")
        let home = await call("look at Home", "look", "{}")
        let front = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in queue.async { c.resume(returning: PKInProcess.shared().frontApp()) } }
        note("after Home the front app is \(front["bundleId"] as? String ?? "?")", ["step": "home_seen", "bundle": front["bundleId"] as? String ?? "", "look_mentions_home": home.lowercased().contains("springboard") || home.contains("Home")])
    }

    private func frontField() async -> CGPoint? {
        await withCheckedContinuation { (c: CheckedContinuation<CGPoint?, Never>) in
            queue.async {
                var code: NSString?
                guard let xml = PKInProcess.shared().sourceXML(nil, code: &code),
                      let match = xml.firstMatch(of: /<XCUIElementType(?:SearchField|TextField|TextView)\b[^>]*? x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"/),
                      let fx = Double(match.1), let fy = Double(match.2), let w = Double(match.3), let h = Double(match.4), w > 0, h > 0 else { c.resume(returning: nil); return }
                c.resume(returning: CGPoint(x: fx + w / 2, y: fy + h / 2))
            }
        }
    }

    private func focusedValue() async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            queue.async {
                var code: NSString?
                var focus: NSDictionary?
                _ = PKInProcess.shared().sourceXML(&focus, code: &code)
                c.resume(returning: focus?["value"] as? String)
            }
        }
    }

    /// Whether ending a session ends the Automation Running banner: a session of its own (not the
    /// shared one), one tap, a hold, then its connection closed. Only meaningful in a fresh process.
    func separateTrial() async {
        guard begin("separate session trial") else { return }
        defer { end() }
        let point = CGPoint(x: Double(x) ?? 201, y: Double(y) ?? 437)
        let hold = Double(delay) ?? 8
        note("separate session: open, Automation Mode, tap [\(Int(point.x)), \(Int(point.y))], hold \(Int(hold)) s, close", ["step": "separate_start"])
        let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().separateSessionTrial(at: point, hold: hold)) }
        }
        let line = result.keys.sorted().map { "\($0)=\(result[$0].map { "\($0)" } ?? "")" }.joined(separator: " ")
        note("separate session: \(line); watch whether the banner goes now", (["step": "separate_result"] as [String: Any]).merging(result) { a, _ in a })
    }

    /// Nothing in Poki may listen on WebDriverAgent's port on the in-process path: a connection to
    /// 127.0.0.1:8100 from inside the app has to be refused.
    func portCheck() async {
        guard begin("port 8100") else { return }
        defer { end() }
        let result = await probe(label: "8100", host: "127.0.0.1", port: 8100, timeout: 2)
        note("127.0.0.1:8100: \(result.outcome) \(result.detail) after \(result.milliseconds) ms", ["step": "port_8100", "outcome": result.outcome, "detail": result.detail])
    }

    /// The gym scorecard on the in-process path: the same scenarios and checks as the runner path's
    /// executable, through this app's PokiCore and InProcessWDA. Approvals are answered the way the
    /// owner would on the Live Activity (the scorecard says when and how).
    func gymScorecard(model: AppModel) async {
        guard begin("gym scorecard") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Gym scorecard")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let transcript = GymTranscript()
        // The owner's side of approvals: PokiCore asks, the approver answers after the delay the
        // scorecard set (there is no session on, so the app's own list does not see them).
        let asked = GymAskedApprovals()
        let approver = GymApprover { id, approved in
            if let approval = asked.byID[id] { model.resolve(approval, approved: approved) }
        }
        model.onProbeApproval = { approval in
            asked.byID[approval.id] = approval
            NSLog("PokiGym approval asked: %@ (%@)", approval.summary, approval.reason)
            approver.requested(id: approval.id)
        }
        defer { model.onProbeApproval = nil }
        var env = GymEnvironment(call: { name, args in
            let answer = await model.phoneToolWithPicture(name, arguments: args.serialized())
            return (answer.text, answer.jpeg.map { [$0] } ?? [])
        }, log: { line in
            transcript.lines.append(line)
            NSLog("PokiGym %@", String(line.prefix(900)))
        })
        env.pictures = documents.appendingPathComponent("gym-pictures")
        env.approveNext = { approver.next($0) }
        env.path = "in-process"
        let scorecard = GymScorecard(env: env)
        await scorecard.run()
        let report = scorecard.report
        transcript.lines.append(report)
        NSLog("PokiGym %@", report)
        note("gym scorecard: \(scorecard.rows.filter { $0.ms > 0 }.count) calls, \(scorecard.failures.count) failures", ["step": "gym", "failures": scorecard.failures])
        try? transcript.lines.joined(separator: "\n").write(to: documents.appendingPathComponent("gym-scorecard.txt"), atomically: true, encoding: .utf8)
    }

    /// `-pokiInProcess chat -pokiProbeModelURL http://127.0.0.1:8765/v1`: Poki's own agent end to end on
    /// this path. The chat is pointed at an OpenAI-compatible endpoint (on CI, a scripted model on the
    /// Mac), the owner sends a task, pi runs it with look and do on the phone, the session is saved; then an
    /// outside agent's `ask_poki` runs a second task as a hand-off. Into Documents/inprocess-probe.json.
    func chatCycle(model: AppModel, liveOpenRouter: Bool = false) async {
        guard begin("chat with Poki's agent") else { return }
        defer { end() }
        guard await prepare() else { return }
        model.inProcessReadyForProbe()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Chat probe")
        defer { UIApplication.shared.endBackgroundTask(background) }
        let defaults = UserDefaults.standard
        if liveOpenRouter {
            // The real provider, credential, chat loop and PokiCore tools. No proxy on the Mac and
            // no fixture-only tool catalog. A Debug Simulator FIFO may still be importing the key.
            for _ in 0..<200 where !ModelKeys.hasKey(.openrouter) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard ModelKeys.hasKey(.openrouter) else {
                note("OpenRouter account missing", ["step": "chat_missing_key"])
                return
            }
            ModelKeys.selectedProvider = .openrouter
        } else {
            ModelKeys.customURL = defaults.string(forKey: "pokiProbeModelURL") ?? "http://127.0.0.1:8765/v1"
            ModelKeys.customModel = defaults.string(forKey: "pokiProbeModel") ?? "poki-mock"
            ModelKeys.selectedProvider = .custom
        }
        note("chat account: \(ModelKeys.selectedProvider.name), \(ModelKeys.selectedModel)",
             ["step": "chat_account", "provider": ModelKeys.selectedProvider.rawValue, "model": ModelKeys.selectedModel])
        AskPoki.refresh()
        guard let chat = AskPoki.chat else { note("no chat", ["step": "chat_missing"]); return }
        chat.newConversation()
        let task = defaults.string(forKey: "pokiProbeTask") ?? "Open the Poki fixture app and tell me what it shows."
        let t0 = ProcessInfo.processInfo.systemUptime
        chat.send(task)
        for _ in 0..<1200 where chat.running { try? await Task.sleep(for: .milliseconds(250)) }
        let seconds = ProcessInfo.processInfo.systemUptime - t0
        let replies: [String] = chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } }
        let problems: [String] = chat.entries.compactMap { if case .note(.problem(let why)) = $0.kind { why } else { nil } }
        note("chat task: \(chat.calls.count) tool calls in \(String(format: "%.1f", seconds)) s, \(replies.count) replies, \(problems.count) problems",
             ["step": "chat", "running": chat.running, "seconds": seconds, "calls": chat.calls.map { ["name": $0.name, "ok": $0.ok, "ms": $0.ms] },
              "replies": replies, "problems": problems])
        // Saved like any conversation: the Sessions list shows it.
        try? await Task.sleep(for: .seconds(1))
        let saved = SessionStore.shared.session(chat.sessionID)
        note("chat session saved: \(saved != nil)", ["step": "chat_saved", "saved": saved != nil, "entries": saved?.entries.count ?? 0, "calls": saved?.calls.count ?? 0])
        // The paid live-provider acceptance executes exactly the requested task, not an additional
        // unrelated fixture hand-off. Full call receipts remain in Poki's normal Sessions store.
        if liveOpenRouter { return }
        // An outside agent hands a task over.
        let t1 = ProcessInfo.processInfo.systemUptime
        let handoff = await model.phoneToolWithPicture("ask_poki", arguments: "{\"task\":\"Open the Poki fixture app and tell me what it shows.\"}")
        note("ask_poki: \(handoff.isError ? "failed" : "ok") in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - t1)) s",
             ["step": "ask_poki", "error": handoff.isError, "text": String(handoff.text.prefix(4000))])
        let handoffs = SessionStore.shared.sessions.filter { $0.kind == .handoff }
        note("hand-off sessions saved: \(handoffs.count)", ["step": "handoff_saved", "count": handoffs.count, "entries": handoffs.first?.entries.count ?? 0])
    }

    /// The scorecard's log, kept for Documents/gym-scorecard.txt.
    private final class GymTranscript { var lines: [String] = [] }
    /// The approvals PokiCore asked for during the scorecard, by id.
    private final class GymAskedApprovals { var byID: [String: PendingApproval] = [:] }

    // MARK: Steps

    func prepare() async -> Bool {
        note("prepare: opening the daemon session and Automation Mode", ["step": "prepare_start"])
        let result = await withCheckedContinuation { (c: CheckedContinuation<[String: Any], Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().prepare()) }
        }
        let ok = (result["ok"] as? Bool) == true
        let seconds = String(format: "%.3f", (result["seconds"] as? Double) ?? 0)
        note(ok ? "prepare: ready in \(seconds) s, generation \(result["generation"] ?? "?"), enable \((result["reused"] as? Bool) == true ? "reused" : "new")"
                : "prepare: failed in \(seconds) s: \(result["code"] ?? "?") \(result["detail"] ?? "")",
             result.merging(["step": "prepare"]) { a, _ in a })
        return ok
    }

    private func touch(_ fingers: [[PKTouchPoint]], _ what: String) async -> PKOutcome {
        let outcome = await withCheckedContinuation { (c: CheckedContinuation<PKOutcome, Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().touch(fingers, timeout: 5)) }
        }
        report(what, outcome)
        return outcome
    }

    private func type(_ text: String) async -> PKOutcome {
        let outcome = await withCheckedContinuation { (c: CheckedContinuation<PKOutcome, Never>) in
            queue.async { c.resume(returning: PKInProcess.shared().type(text, timeout: 10)) }
        }
        report("type \(text.count) characters", outcome)
        return outcome
    }

    private func report(_ what: String, _ o: PKOutcome) {
        let delivery = ["not_sent", "sent", "unknown"][o.delivery.rawValue]
        note("\(what): \(delivery) in \(String(format: "%.3f", o.seconds)) s, generation \(o.generation)\(o.code.map { ", \($0)" } ?? "")\(o.detail.map { " (\($0))" } ?? "")",
             ["step": what, "delivery": delivery, "seconds": o.seconds, "generation": o.generation, "code": o.code ?? NSNull()])
    }

    // MARK: Record

    func begin(_ what: String) -> Bool {
        guard !running else { return false }
        running = true
        record = []
        note("start: \(what)", ["step": "begin", "what": what])
        return true
    }

    func end() {
        running = false
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]) else { return }
        try? data.write(to: directory.appendingPathComponent("inprocess-probe.json"))
    }

    func note(_ line: String, _ fields: [String: Any]) {
        var entry = fields
        entry["uptime"] = ProcessInfo.processInfo.systemUptime
        record.append(entry)
        lines.append(line)
        NSLog("PokiInProcess %@", line)
        AppLog.shared.add("inprocess", line)
    }
}

/// Settings > Diagnostics: the automation path switch and the probes (kept in this branch, where
/// DiagnosticsView hosts it; ESP-152 removed it on a line where it had no caller).
struct InProcessSection: View {
    @ObservedObject var probe = InProcessProbe.shared
    @AppStorage("automationPath") private var path = AutomationPath.nativeServices.rawValue
    private let running = AutomationPath.current
    @State private var ime = NativeServicesWDA(screen: UIScreen.main.bounds.size)
    @State private var pinyin = "nihao"
    @State private var imeStatus = ""
    @State private var imeBusy = false
    @State private var imeTask: Task<Void, Never>?

    var body: some View {
        Section {
            Picker("Method", selection: $path) {
                Text("XCTest session").tag(AutomationPath.inProcess.rawValue)
                Text("Native services (experimental)").tag(AutomationPath.nativeServices.rawValue)
            }
            if path != running.rawValue {
                Text("Takes effect when Poki starts again.").font(.caption).foregroundStyle(.orange)
            }
            ProbeField(probe: probe).frame(height: 44)
            DisclosureGroup("Chinese keyboard experiment") {
                Text("Select Chinese Pinyin on the test field first. Actions wait 2 seconds so you can focus the field. Inspect the candidates before choosing; Space may insert a space if no composition is active.")
                    .font(.caption)
                TextField("Pinyin", text: $pinyin).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Compose Pinyin") { imeAction(text: pinyin) }.disabled(imeBusy)
                Button("Switch to Chinese and verify") { imeAction(key: "next_input_source") }.disabled(imeBusy)
                Button("Read candidate accessibility") { imeAction(read: true) }.disabled(imeBusy)
                HStack {
                    Button("Previous") { imeAction(key: "left") }
                    Button("Next") { imeAction(key: "right") }
                    Button("Choose (Space)") { imeAction(key: "space") }
                }.disabled(imeBusy)
                HStack {
                    Button("More candidates") { imeAction(key: "down") }
                    Button("Backspace") { imeAction(key: "backspace") }
                    Button("End experiment") { imeAction(end: true) }
                }.disabled(imeBusy)
                Text(imeStatus).font(.caption).textSelection(.enabled)
                Text("Composition requires Chinese as the focused test field’s active input language. This verifies Chinese, not the specific Pinyin layout. The accessibility read may include app text: review it before sharing.").font(.caption)
            }
            HStack {
                Button("Port 8100") { Task { await probe.portCheck() } }
                Button("Separate session") { Task { await probe.separateTrial() } }
            }.disabled(probe.running)
            Button("Compare methods (5 rounds)") { Task { await probe.benchmark(rounds: 5) } }.disabled(probe.running)
            HStack {
                Button("Prepare") { Task { await probe.prepareOnly() } }
                Spacer()
                Button("Read") { Task { await probe.readOnly() } }
                Spacer()
                Button("Self test") { Task { await probe.selfTest() } }
            }
            .buttonStyle(.borderless).disabled(probe.running)
            HStack {
                TextField("x", text: $probe.x).keyboardType(.numberPad)
                TextField("y", text: $probe.y).keyboardType(.numberPad)
                TextField("s", text: $probe.delay).keyboardType(.numberPad)
                Button("Later") { Task { await probe.later() } }.buttonStyle(.borderless).disabled(probe.running)
            }
            .monospacedDigit()
            ForEach(probe.lines.indices.reversed(), id: \.self) { i in Text(probe.lines[i]).font(.caption2.monospaced()).textSelection(.enabled) }
        } header: {
            Text("In-process automation")
        } footer: {
            Text("Native services is an experimental banner-free path using the same paired accessibility, screenshot and HID services as the Mac/Linux bridge. PokiCore keeps the same control logic, approvals, action timing and typing cadence as the standard paths. Changes take effect when Poki starts again.")
        }
        .onAppear {
            if path == AutomationPath.runner.rawValue { path = AutomationPath.nativeServices.rawValue }
        }
        .onDisappear {
            let pending = imeTask
            pending?.cancel()
            Task {
                await pending?.value
                do { try await ime.ime(end: true) }
                catch { imeStatus = "Keyboard detach failed: \(error.localizedDescription)" }
                await ime.reset()
            }
        }
    }

    private func imeAction(text: String = "", key: String? = nil, end: Bool = false, read: Bool = false) {
        imeBusy = true
        imeStatus = "Focus the test field now…"
        imeTask = Task { @MainActor in
            defer { imeBusy = false }
            do {
                if !end { try await Task.sleep(for: .seconds(2)) }
                try Task.checkCancellation()
                if read {
                    imeStatus = try await ime.imeAccessibilitySnapshot()
                    return
                }
                if !end {
                    guard probe.focusedInputLanguage != nil else {
                        try await ime.ime(end: true)
                        imeStatus = "Not verified: focus the test field in Poki first. Nothing typed."
                        return
                    }
                    // Attaching a hardware keyboard can change the active mode.
                    // Observe after attachment, not just before sending the command.
                    try await ime.ime()
                    try await Task.sleep(for: .milliseconds(250))
                    if key == "next_input_source" {
                        for _ in 0..<8 {
                            try Task.checkCancellation()
                            guard probe.focusedInputLanguage != nil else { break }
                            if InProcessProbe.isChineseInputLanguage(probe.focusedInputLanguage) { break }
                            try await ime.ime(key: "next_input_source")
                            try await Task.sleep(for: .milliseconds(350))
                        }
                    }
                    guard let language = probe.focusedInputLanguage,
                          InProcessProbe.isChineseInputLanguage(language) else {
                        try await ime.ime(end: true)
                        imeStatus = "Chinese not verified (active: \(probe.focusedInputLanguage ?? "unknown")). No composition or candidate-selection key sent. Enable a Chinese keyboard in iOS Settings."
                        return
                    }
                    if key == "next_input_source" {
                        imeStatus = "Verified Chinese input: \(language) on the focused test field"
                        return
                    }
                }
                try await ime.ime(text: text, key: key, end: end)
                imeStatus = end ? "Keyboard detached" : "Sent — inspect the composition and candidates"
            } catch {
                imeStatus = error.localizedDescription
                do { try await ime.ime(end: true) }
                catch { imeStatus += " · Keyboard detach failed: \(error.localizedDescription)" }
            }
        }
    }
}

private struct ProbeField: UIViewRepresentable {
    let probe: InProcessProbe
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = "In-process test field"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.accessibilityIdentifier = "inprocess-field"
        probe.field = field
        return field
    }
    func updateUIView(_ view: UITextField, context: Context) { probe.field = view }
}
