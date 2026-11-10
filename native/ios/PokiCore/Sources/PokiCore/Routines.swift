import Foundation

// Routines and notes: the agent's memory, kept on the phone and shared by every agent that drives it
// (Poki's own chat and any MCP client over the relay).
//
// A task's `do` actions are recorded as they are sent, each target as what it is (role, label,
// identifier, and where it was) rather than its number, which changes from read to read. A recorded
// task saved under a name is a routine; `do {run: "name"}` replays it in one call. Each step waits for
// its target to be on screen, acts only on a single match, and stops at the first screen that differs,
// so a routine never taps the wrong thing: the agent goes on from the read the stop answers with.
// A routine keeps its runs, so one that keeps stopping is marked stale and no longer offered.
//
// Notes are short facts the agent or the owner saves ("Mom is the contact Mama"). Both live in one
// JSON file in the app's own storage; a copy in Documents/AgentBackup is what Poki Setup backs up.
// Typed text is a parameter of the routine; text typed into a password field is never stored.

/// What a step acts on, as it was found when the step was recorded.
public struct RoutineTarget: Codable, Equatable, Sendable {
    public var type: String
    public var label: String?
    public var identifier: String?
    /// The element's centre when recorded: picks one of several matches that are otherwise alike.
    public var x: Double
    public var y: Double

    init(_ e: Element) {
        type = e.type
        label = e.label.flatMap { $0.isEmpty ? nil : $0 }
        identifier = e.identifier.flatMap { $0.isEmpty ? nil : $0 }
        let c = e.frame.centre
        x = (c.x * 10).rounded() / 10
        y = (c.y * 10).rounded() / 10
    }

    public var describe: String { "\(type) \"\(label ?? identifier ?? "")\"" }

    func matches(_ e: Element) -> Bool {
        guard !e.fromPicture, e.type == type else { return false }
        if let identifier, e.identifier == identifier { return label == nil || e.label == label }
        return (e.label.flatMap { $0.isEmpty ? nil : $0 }) == label && (identifier == nil || e.identifier == nil || e.identifier == identifier)
    }
}

/// One recorded action. `action` is the `do` action with its element number taken out; `target` is
/// what the number pointed at. A type's text is `{{name}}` of a parameter.
public struct RoutineStep: Codable, Equatable, Sendable {
    public var action: JSON
    public var target: RoutineTarget?
    /// The app in front when the step was sent.
    public var app: String?
    /// A type into a password field: the text was not kept, so a run stops here for the agent.
    public var secret: Bool?
    /// An observed user correction/checkpoint; never replayed unattended.
    public var userDemonstrated: Bool? = nil
}

public struct RoutineStop: Codable, Equatable, Sendable {
    public var step: Int
    public var why: String
    public var at: Date
}

public struct Routine: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// The app the routine works in (it is launched first when another app is in front).
    public var app: String?
    public var steps: [RoutineStep]
    /// Parameters and the values they were recorded with: `{{text_1}}` in a type.
    public var params: [String: String]
    /// Texts that must be on screen when the routine has run (its end check).
    public var expect: [String]
    /// Labels whose values the run reads off the last screen (a learned readout).
    public var read: [String]
    public var runs: Int
    public var ok: Int
    /// Runs that stopped in a row; two or more mark the routine stale.
    public var failuresInARow: Int
    public var lastStop: RoutineStop?
    public var lastMs: Int?
    public var savedBy: String
    public var created: Date
    public var updated: Date

    public var stale: Bool { failuresInARow >= 2 }
    public var summary: String {
        "\(name): \(description.isEmpty ? "" : description + "; ")\(app.map { "in \($0), " } ?? "")\(steps.count) steps, \(runs) runs, \(ok) ok\(stale ? ", STALE (stopped \(failuresInARow) times in a row\(lastStop.map { " at step \($0.step): \($0.why)" } ?? ""))" : "")\(params.isEmpty ? "" : ", with: " + params.keys.sorted().map { "\($0) (recorded \"\(params[$0]!.prefix(30))\")" }.joined(separator: ", "))"
    }
}

public struct MemoryNote: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var by: String
    public var at: Date
}

/// One routine run, for the maintainers' log bundle.
public struct RoutineRunLog: Codable, Equatable, Sendable {
    public var routine: String
    public var at: Date
    public var ms: Int
    public var outcome: String
    public var steps: [String]
}

/// The file: routines, notes and the latest runs. The backup file has the same shape plus `schema`.
struct MemoryFile: Codable {
    var schema = RoutineStore.schema
    var exported: Date?
    var routines: [Routine] = []
    var notes: [MemoryNote] = []
    var runs: [RoutineRunLog] = []
    /// What the app adds to a backup (its saved sessions), opaque here.
    var extras: [String: JSON]?
}

/// The agent's memory: thread-safe, saved to one file after every change.
public final class RoutineStore: @unchecked Sendable {
    public static let schema = "poki.agent-backup/1"
    public static let backupName = "poki-agent-backup.json"
    static let maxNotes = 50, maxRoutines = 200, maxRuns = 50, maxNoteLength = 300

    private let lock = NSLock()
    private var file = MemoryFile()
    /// Where the memory is kept (nil: in memory only, as in tests).
    public let url: URL?
    /// Where a copy goes after every change, for Poki Setup's backup (Documents/AgentBackup).
    public let backupDirectory: URL?
    private var lastBackupHash: String?

    public init(url: URL?, backupDirectory: URL? = nil) {
        self.url = url
        self.backupDirectory = backupDirectory
        if let url, let data = try? Data(contentsOf: url), let saved = try? Self.decoder.decode(MemoryFile.self, from: data) {
            file = saved
        }
        if let backupDirectory { lastBackupHash = try? String(contentsOf: backupDirectory.appendingPathComponent(".last-written"), encoding: .utf8) }
    }

    /// The shared memory of the app (Application Support/Poki/agent-memory.json, and its backup copy
    /// in Documents/AgentBackup). The app may replace it before PokiCore starts.
    public static var shared: RoutineStore = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Poki", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AgentBackup", isDirectory: true)
        #if os(iOS)
        return RoutineStore(url: support?.appendingPathComponent("agent-memory.json"), backupDirectory: documents)
        #else
        return RoutineStore(url: nil)
        #endif
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func withFile<T>(_ change: Bool = false, _ body: (inout MemoryFile) throws -> T) rethrows -> T {
        lock.lock()
        let result = try body(&file)
        let snapshot = change ? file : nil
        lock.unlock()
        if let snapshot { persist(snapshot) }
        return result
    }

    /// Notified after every change (the app's Memory page).
    public var onChange: (@Sendable () -> Void)?

    private func persist(_ snapshot: MemoryFile) {
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? Self.encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        if let backupDirectory, let data = try? exportData(includeExtras: false) {
            try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let target = backupDirectory.appendingPathComponent(Self.backupName)
            try? data.write(to: target, options: .atomic)
            let hash = Self.hash(data)
            lastBackupHash = hash
            try? hash.write(to: backupDirectory.appendingPathComponent(".last-written"), atomically: true, encoding: .utf8)
        }
        onChange?()
    }

    static func hash(_ data: Data) -> String {
        // FNV-1a: only to tell our own copy from one put there by Poki Setup.
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// A backup file Poki Setup put in Documents/AgentBackup since the app last wrote it is merged in.
    /// Returns what was imported, or nil when there was nothing new.
    @discardableResult
    public func importRestoredBackup() -> String? {
        guard let backupDirectory else { return nil }
        let target = backupDirectory.appendingPathComponent(Self.backupName)
        guard let data = try? Data(contentsOf: target), Self.hash(data) != lastBackupHash else { return nil }
        return try? importData(data, by: "restore")
    }

    // MARK: Reading

    public var routines: [Routine] { withFile { $0.routines } }
    public var notes: [MemoryNote] { withFile { $0.notes } }
    public var runLog: [RoutineRunLog] { withFile { $0.runs } }
    public func routine(named name: String) -> Routine? {
        withFile { f in f.routines.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    }

    // MARK: Changing

    public func save(_ routine: Routine) {
        withFile(true) { f in
            var r = routine
            if let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(routine.name) == .orderedSame }) {
                let old = f.routines[i]
                r.created = old.created
                // A routine saved again after it stopped is the path that worked: its record starts over.
                if old.steps == r.steps { r.runs = old.runs; r.ok = old.ok; r.failuresInARow = old.failuresInARow; r.lastStop = old.lastStop }
                f.routines[i] = r
            } else {
                f.routines.append(r)
                if f.routines.count > Self.maxRoutines { f.routines.removeFirst(f.routines.count - Self.maxRoutines) }
            }
        }
    }

    @discardableResult
    public func forget(_ name: String) -> Bool {
        withFile(true) { f in
            let before = f.routines.count
            f.routines.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return f.routines.count != before
        }
    }

    @discardableResult
    public func rename(_ name: String, to new: String) -> Bool {
        withFile(true) { f in
            guard let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
            f.routines[i].name = new
            f.routines[i].updated = Date()
            return true
        }
    }

    public func update(_ name: String, _ change: (inout Routine) -> Void) {
        withFile(true) { f in
            guard let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            change(&f.routines[i])
        }
    }

    @discardableResult
    public func remember(_ text: String, by: String) -> MemoryNote? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return withFile(true) { f in
            if let same = f.notes.first(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { return same }
            let note = MemoryNote(id: String(UUID().uuidString.prefix(8)).lowercased(), text: String(clean.prefix(Self.maxNoteLength)), by: by, at: Date())
            f.notes.append(note)
            if f.notes.count > Self.maxNotes { f.notes.removeFirst(f.notes.count - Self.maxNotes) }
            return note
        }
    }

    @discardableResult
    public func forgetNote(_ idOrText: String) -> Bool {
        withFile(true) { f in
            let before = f.notes.count
            f.notes.removeAll { $0.id == idOrText || $0.text.caseInsensitiveCompare(idOrText) == .orderedSame }
            return f.notes.count != before
        }
    }

    public func editNote(_ id: String, text: String) {
        withFile(true) { f in
            guard let i = f.notes.firstIndex(where: { $0.id == id }) else { return }
            f.notes[i].text = String(text.prefix(Self.maxNoteLength))
        }
    }

    func logRun(_ log: RoutineRunLog) {
        withFile(true) { f in
            f.runs.append(log)
            if f.runs.count > Self.maxRuns { f.runs.removeFirst(f.runs.count - Self.maxRuns) }
        }
    }

    public func clearAll() { withFile(true) { $0 = MemoryFile() } }

    // MARK: Export and import

    /// What the app adds to a backup and takes back from one (its saved chat sessions). Off unless set.
    public var extrasProvider: (@Sendable () -> [String: JSON])?
    public var extrasRestorer: (@Sendable ([String: JSON]) -> Void)?

    /// The backup file: routines, notes and the run log; with `includeExtras`, what the app adds.
    public func exportData(includeExtras: Bool = false) throws -> Data {
        var snapshot = withFile { $0 }
        snapshot.schema = Self.schema
        snapshot.exported = Date()
        snapshot.extras = includeExtras ? extrasProvider?() : nil
        return try Self.encoder.encode(snapshot)
    }

    /// Merges a backup in: a routine with the same name is replaced when the incoming one is newer;
    /// notes are added unless the same text is there. Returns what changed, in words.
    @discardableResult
    public func importData(_ data: Data, by: String) throws -> String {
        let incoming: MemoryFile
        do { incoming = try Self.decoder.decode(MemoryFile.self, from: data) }
        catch { throw ImportError("not a Poki agent backup: \(error)") }
        guard incoming.schema.hasPrefix("poki.agent-backup/") else { throw ImportError("not a Poki agent backup (schema \(incoming.schema))") }
        guard incoming.schema == Self.schema else { throw ImportError("a backup of a newer Poki (\(incoming.schema)); update Poki to import it") }
        var added = 0, replaced = 0, kept = 0, notes = 0
        withFile(true) { f in
            for r in incoming.routines where !r.name.isEmpty {
                if let i = f.routines.firstIndex(where: { $0.name.caseInsensitiveCompare(r.name) == .orderedSame }) {
                    if r.updated > f.routines[i].updated { f.routines[i] = r; replaced += 1 } else { kept += 1 }
                } else { f.routines.append(r); added += 1 }
            }
            for n in incoming.notes where !f.notes.contains(where: { $0.text.caseInsensitiveCompare(n.text) == .orderedSame }) {
                f.notes.append(n); notes += 1
            }
            if f.notes.count > Self.maxNotes { f.notes.removeFirst(f.notes.count - Self.maxNotes) }
        }
        if let extras = incoming.extras, !extras.isEmpty { extrasRestorer?(extras) }
        return "imported: \(added) routines added, \(replaced) replaced by newer ones, \(kept) kept (ours were newer), \(notes) notes added\(incoming.extras?.isEmpty == false ? ", and the app's saved sessions" : "")"
    }

    public struct ImportError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// The maintainers' bundle: every routine with its record, the latest runs and the notes' count.
    /// No screenshots and no typed text beyond what the routines keep as parameters.
    public func debugBundle(extra: [String: JSON] = [:]) -> Data {
        let snapshot = withFile { $0 }
        var bundle: [String: JSON] = extra
        bundle["schema"] = "poki.agent-debug/1"
        bundle["made"] = .string(ISO8601DateFormatter().string(from: Date()))
        bundle["routines"] = .array(snapshot.routines.map { r in
            ["name": .string(r.name), "app": r.app.map(JSON.string) ?? .null, "steps": .array(r.steps.map { s in
                ["action": s.action, "target": s.target.map { .string($0.describe) } ?? .null, "app": s.app.map(JSON.string) ?? .null] }),
             "runs": .number(Double(r.runs)), "ok": .number(Double(r.ok)), "stale": .bool(r.stale),
             "last_stop": r.lastStop.map { ["step": .number(Double($0.step)), "why": .string($0.why), "at": .string(ISO8601DateFormatter().string(from: $0.at))] } ?? .null,
             "last_ms": r.lastMs.map { .number(Double($0)) } ?? .null]
        })
        bundle["runs"] = .array(snapshot.runs.map { l in
            ["routine": .string(l.routine), "at": .string(ISO8601DateFormatter().string(from: l.at)), "ms": .number(Double(l.ms)), "outcome": .string(l.outcome), "steps": .array(l.steps.map(JSON.string))]
        })
        bundle["notes"] = .number(Double(snapshot.notes.count))
        return JSON.object(bundle).data()
    }

    // MARK: For the agent

    /// The brief goes into every task's prompt, so it stays this short (in characters); the routines
    /// tool lists the rest.
    static let maxBriefLength = 4000

    /// What a model should know at the start of a task: the routines that fit it best (stale ones
    /// left out) in up to half of `maxBriefLength`, and the newest notes in the rest. Empty when
    /// nothing is saved.
    public func brief(for task: String, app: String? = nil, limit: Int = 12) -> String {
        let (routines, notes) = withFile { ($0.routines, $0.notes) }
        let words = Set(Self.words(task))
        let fit = routines.filter { !$0.stale }.map { r -> (Routine, Int) in
            let score = Set(Self.words(r.name + " " + r.description)).intersection(words).count * 3 + (app != nil && r.app == app ? 2 : 0)
            return (r, score)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updated > $1.0.updated }.prefix(limit).map(\.0)
        var room = Self.maxBriefLength
        func section(_ header: String, _ items: [String], within limit: Int) -> [String] {
            var left = min(room, limit) - header.count - 1
            var taken: [String] = []
            for item in items where item.count + 1 <= left {
                taken.append(item)
                left -= item.count + 1
            }
            guard !taken.isEmpty else { return [] }
            room -= ([header] + taken).reduce(0) { $0 + $1.count + 1 }
            return [header] + taken
        }
        let routineLines = section("Saved routines: do {run: \"name\"} replays one in a single call and stops cleanly at a screen that differs, so try a routine that fits before stepping by hand (with: {text_1: \"…\"} changes what it types). The routines tool lists, shows, edits and saves them:",
                                   fit.map { "- \($0.summary)" }, within: Self.maxBriefLength / 2)
        let noteLines = section("Notes saved about the owner and their phone, newest first (use them; the routines tool's remember adds one, forget_note drops one):",
                                notes.suffix(20).reversed().map { "- \($0.text)" }, within: room)
        return (noteLines + routineLines).joined(separator: "\n")
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
    }
}

// MARK: Recording and replay in `do`

/// A step as recorded while the task ran, with what the screen held before it (for the end check).
struct RecordedStep {
    var step: RoutineStep
    var typed: String?
    var keysBefore: Set<String>
}

extension Computer {
    /// The `do` action as a routine step: element numbers become targets. nil for what is not kept
    /// (a handoff, a run, which records its own steps).
    func recordable(_ action: JSON) -> RecordedStep? {
        guard case .object(var o) = action, o["handoff"] == nil, o["run"] == nil else { return nil }
        var target: RoutineTarget?
        var typed: String?
        var secret: Bool?
        func element(_ spec: JSON?) -> Element? {
            guard let spec else { return nil }
            if let n = spec.int, spec.array == nil, case .number = spec { return refs[n] }
            if case .string = spec, let n = spec.int { return refs[n] }
            if let n = spec["ref"]?.int { return refs[n] }
            return nil
        }
        func point(_ e: Element) -> JSON { let c = e.frame.centre; return [.number(c.x.rounded()), .number(c.y.rounded())] }
        for key in ["tap", "long_press"] {
            if let spec = o[key], let e = element(spec) {
                target = RoutineTarget(e)
                if case .object(var inner) = spec { inner["ref"] = "@"; o[key] = .object(inner) } else { o[key] = "@" }
            }
        }
        if let text = o["type"]?.text {
            if let e = element(o["ref"]) { target = RoutineTarget(e); o["ref"] = "@" }
            let hidden = describe(action).hasSuffix("(hidden)")
            if hidden { secret = true; o["type"] = "" } else { typed = text }
        }
        if case .object(var s) = o["scroll_to"], let e = element(s["ref"]) {
            s["ref"] = nil
            s["text"] = .string(e.label ?? e.text)
            o["scroll_to"] = .object(s)
        }
        if case .object(var s) = o["scroll_to"], s["in"] != nil { s["in"] = nil; o["scroll_to"] = .object(s) }
        if case .object(var s) = o["swipe"], s["in"] != nil { s["in"] = nil; o["swipe"] = .object(s) }
        if case .object(var d) = o["drag"] {
            for k in ["from", "to"] { if let e = element(d[k]) { d[k] = point(e) } }
            o["drag"] = .object(d)
        }
        if case .object(var p) = o["pinch"], let e = element(.object(p)) { p["ref"] = nil; let c = e.frame.centre; p["x"] = .number(c.x.rounded()); p["y"] = .number(c.y.rounded()); o["pinch"] = .object(p) }
        let keys = Set(listed.map(\.element.key))
        return RecordedStep(step: RoutineStep(action: .object(o), target: target, app: lastForeground?.bundleID, secret: secret), typed: typed, keysBefore: keys)
    }

    /// The task's recorded steps as a routine (nil and why, when they cannot make one).
    func routine(named name: String, description: String, read: [String], expect: [String]?, by: String) -> (Routine?, String) {
        if traceHasUserGap && !config.userRoutineLearning() {
            return (nil, "This task includes a user intervention. User-assisted routine creation is disabled; save an evidence-backed note instead.")
        }
        let recorded = trace
        guard !recorded.isEmpty else { return (nil, "nothing was recorded in this task yet: a routine is made of the do actions sent since the task began (the first look or do after a finish)") }
        var params: [String: String] = [:]
        var steps: [RoutineStep] = []
        for r in recorded {
            var s = r.step
            if let text = r.typed, case .object(var o) = s.action {
                let id = params.first(where: { $0.value == text })?.key ?? "text_\(params.count + 1)"
                params[id] = text
                o["type"] = .string("{{\(id)}}")
                s.action = .object(o)
            }
            steps.append(s)
        }
        // The end check: what the last screen shows that was not there before the last step (its
        // headings and texts, three at most), else what the step went to.
        var checks = expect ?? []
        if expect == nil, let last = recorded.last {
            let fresh = listed.map(\.element).filter { e in
                !e.fromPicture && !e.text.isEmpty && !Self.containers.contains(e.type) && !last.keysBefore.contains(e.key) && e.text.count <= 60
                    && listed.filter({ $0.element.key == e.key }).count == 1
            }
            let preferred = fresh.filter { ["NavigationBar", "StaticText", "Heading"].contains($0.type) } + fresh.filter { !["NavigationBar", "StaticText", "Heading"].contains($0.type) }
            checks = Array(preferred.prefix(3).map { $0.label ?? $0.text })
        }
        // The app of the first step that touched something (a launch step was recorded where it began).
        let app = recorded.first(where: { $0.step.target != nil && $0.step.app != nil })?.step.app ?? recorded.first(where: { $0.step.app != nil })?.step.app
        let now = Date()
        let routine = Routine(name: name, description: description, app: app, steps: steps, params: params, expect: checks.filter { !$0.isEmpty }, read: read,
                              runs: 0, ok: 0, failuresInARow: 0, lastStop: nil, lastMs: nil, savedBy: by, created: now, updated: now)
        var notes: [String] = []
        let points = steps.filter { s in s.target == nil && (s.action["tap"]?.array != nil || s.action["long_press"]?.array != nil) }.count
        if points > 0 { notes.append("\(points) step\(points == 1 ? "" : "s") tap a point, not an element: they replay at the same point whatever is there") }
        if steps.contains(where: { $0.secret == true }) { notes.append("a password typed in it was not kept: a run stops there for you to type it") }
        if routine.expect.isEmpty { notes.append("no end check could be chosen from the last screen; give expect: [\"text\"] to add one") }
        return (routine, notes.joined(separator: "; "))
    }

    /// `{run: "name"}` or `{run: {name, with: {text_1: "…"}}}`: the routine's steps in order, each when
    /// its target is on screen. Throws (not sent) at the first step that cannot be done as recorded.
    func runRoutine(_ spec: JSON, until: Double) async throws -> String {
        let name = spec.string ?? spec["name"]?.string ?? ""
        guard let store = memory, let routine = store.routine(named: name) else {
            let known = memory?.routines.prefix(12).map { "\"\($0.name)\"" }.joined(separator: ", ") ?? ""
            throw ActionFailure(message: "no routine named \"\(name)\"\(known.isEmpty ? " (none are saved)" : "; saved: \(known)")", delivery: .notSent)
        }
        var params = routine.params
        if case .object(let given) = spec["with"] { for (k, v) in given { if let t = v.text { params[k] = t } } }
        let started = now()
        var log: [String] = []
        var done = 0
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        func finish(_ outcome: String, stop: RoutineStop?) {
            let ms = Int(((now() - started) * 1000).rounded())
            store.update(routine.name) { r in
                r.runs += 1
                r.lastMs = ms
                if let stop { r.failuresInARow += 1; r.lastStop = stop } else { r.ok += 1; r.failuresInARow = 0 }
            }
            store.logRun(RoutineRunLog(routine: routine.name, at: Date(), ms: ms, outcome: outcome, steps: log))
        }
        func stop(_ index: Int, _ why: String, _ delivery: Delivery = .notSent) -> ActionFailure {
            finish("stopped at step \(index + 1): \(why)", stop: RoutineStop(step: index + 1, why: why, at: Date()))
            let sent = done == 0 ? "no step was sent" : "steps 1 to \(done) were sent"
            return ActionFailure(message: "run \"\(routine.name)\" stopped at step \(index + 1) of \(routine.steps.count): \(why); \(sent). Go on by hand from the screen below; when the task is done, routines {action: \"save\", name: \"\(routine.name)\"} saves the path that worked over this one", delivery: delivery)
        }

        // The app the next step lands in: a launch is not read until a later step reads the screen.
        var front = lastForeground
        // Another app in front: the routine's app is launched first.
        if let app = routine.app, lastForeground?.bundleID != app, routine.steps.first?.action["launch"] == nil, !config.isPoki(Foreground(bundleID: app, name: nil)) {
            do {
                _ = try await perform(["launch": .string(app)], until: until)
                log.append("launched \(app)")
                front = Foreground(bundleID: app, name: nil)
            } catch { throw stop(0, "\(app) could not be launched (\(error))") }
        }

        var previous: String?
        for (index, step) in routine.steps.enumerated() {
            if step.userDemonstrated == true {
                let h = Handoff(id: UUID().uuidString, kind: "other",
                    text: "This routine includes a user-demonstrated correction or navigation. Complete this step yourself, then tap Done. Poki will read the result before continuing.",
                    requested: Date(), ownerOnly: true)
                handoff.value = h
                beginUserIntervention(h)
                emit(.handoffRequested(id: h.id, kind: h.kind, text: h.text, app: lastForeground?.describe))
                throw stop(index, "user-demonstrated checkpoint: waiting for the owner; this step was not replayed")
            }
            if step.secret == true { throw stop(index, "it types into a password field, which a routine never keeps: type it yourself") }
            var action = step.action
            // The text with its parameters filled in.
            if let text = action["type"]?.string, case .object(var o) = action {
                o["type"] = .string(text.replacingParams(params))
                action = .object(o)
            }
            // Each step is held by the rules a do is held by, on the screen it lands on: a step the owner
            // must approve is theirs, and the run hands it back rather than send it.
            var scan: SensitiveScan?
            if let target = step.target {
                // Wait for the target, alone, on screen; after a step that changed nothing yet, give the
                // screen a moment to move on so the same label on the old screen is not taken for it.
                let stepEnds = min(until, now() + config.actionCap)
                var found: Element?
                var why = "\(target.describe) is not on screen"
                var reads = 0
                // The match and its frame in the read before: a target is tapped only once it holds still
                // across two reads (a page sliding in moves its rows, and a tap then is lost), or after 1.5 s.
                var candidate: String?
                let readStart = now()
                while now() < stepEnds - 0.2 {
                    guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, stepEnds - now() - 0.1)), format: config.treeFormat) else { break }
                    reads += 1
                    let elements = listable(tree.elements, screen)
                    let signature = elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
                    let moved = previous == nil || signature != previous || now() - readStart > 0.8
                    lastAll = tree.elements
                    lastForeground = tree.foreground
                    let matches = elements.filter(target.matches)
                    if moved, !matches.isEmpty {
                        let layout = Layout(all: tree.elements, screen: screen)
                        let reachable = matches.filter { layout.touchPoint($0) != nil }
                        let near = reachable.sorted { hypot($0.frame.centre.x - target.x, $0.frame.centre.y - target.y) < hypot($1.frame.centre.x - target.x, $1.frame.centre.y - target.y) }
                        var pick: Element?
                        if near.count == 1 { pick = near[0] }
                        if near.count > 1 {
                            let d0 = hypot(near[0].frame.centre.x - target.x, near[0].frame.centre.y - target.y)
                            let d1 = hypot(near[1].frame.centre.x - target.x, near[1].frame.centre.y - target.y)
                            if d0 < 40, d1 > 2 * d0 + 20 { pick = near[0] }
                            why = "\(near.count) elements match \(target.describe) and none is clearly the recorded one"
                        } else { why = "\(target.describe) is listed but not where a tap reaches it" }
                        if let pick {
                            let here = "\(pick.key)@\(pick.frame.described)"
                            if here == candidate || now() - readStart > 1.5 { found = pick; break }
                            candidate = here
                            why = "\(target.describe) was still moving"
                            continue
                        }
                    }
                    candidate = nil
                    await sleep(seconds: 0.12)
                }
                guard let element = found else { throw stop(index, why + " (\(reads) reads in \(Int(((now() - readStart) * 1000).rounded())) ms)") }
                refs[Self.runRef] = element
                action = Self.replacingTarget(action, with: Self.runRef)
                front = lastForeground
                scan = SensitiveScan(front: lastForeground, secureOnScreen: lastAll.contains(where: \.isSecure))
            } else if config.sensitive.enabled, ["tap", "long_press", "type", "key", "drag"].contains(where: { action[$0] != nil }) {
                // A step recorded without an element (a point, a key) is judged on the screen read now;
                // unread, it is a screen not read yet.
                scan = SensitiveScan(front: front, read: false, secureOnScreen: false)
                if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, until - now() - 0.1)), format: config.treeFormat) {
                    lastAll = tree.elements
                    lastForeground = tree.foreground
                    front = tree.foreground ?? front
                    let elements = listable(tree.elements, screen)
                    scan = SensitiveScan(front: front, secureOnScreen: elements.contains(where: \.isSecure), elements: elements)
                }
            }
            if var scan, let reason = sensitive(action, &scan) {
                refs[Self.runRef] = nil
                throw stop(index, "it needs the owner's approval (\(reason)); send it as an ordinary do so the owner is asked")
            }
            let began = now()
            let kind: String, text: String
            do { (kind, text) = try await perform(action, until: min(until, now() + config.actionCap)) }
            catch let failure as ActionFailure {
                refs[Self.runRef] = nil
                throw stop(index, failure.message, failure.delivery)
            } catch let takeover as RunnerError where takeover.code == "poki user takeover" {
                refs[Self.runRef] = nil
                _ = stop(index, "the owner took over", .unknown)
                throw takeover
            } catch {
                refs[Self.runRef] = nil
                throw stop(index, "\(error)", .unknown)
            }
            refs[Self.runRef] = nil
            if let spec = action["launch"] { front = Foreground(bundleID: spec.string ?? spec["bundle"]?.string, name: nil) }
            done = index + 1
            log.append("\(index + 1) \(text.prefix(80)) (\(Int(((now() - began) * 1000).rounded())) ms)")
            // The step is in this task's record too, so a task that goes on by hand saves whole.
            var recorded = step
            recorded.app = lastForeground?.bundleID ?? step.app
            trace.append(RecordedStep(step: recorded, typed: kind == "type" ? action["type"]?.string : nil, keysBefore: []))
            previous = listable(lastAll, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            // Typing and keys change nothing a next target needs to move away from.
            if kind == "type" || kind == "key" { previous = nil }
        }

        // The end check and the readout.
        var outcome = "\(routine.steps.count) steps in \(Self.seconds(now() - started)) s"
        if !routine.expect.isEmpty || !routine.read.isEmpty {
            let checkEnds = min(until, now() + 3)
            var missing = routine.expect
            var values: [String] = []
            while now() < checkEnds {
                guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, checkEnds - now())), format: config.treeFormat) else { break }
                let texts = listable(tree.elements, screen)
                missing = routine.expect.filter { want in !texts.contains { $0.text.localizedCaseInsensitiveContains(want) } }
                values = routine.read.compactMap { label in
                    guard let e = texts.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame && !($0.value ?? "").isEmpty })
                        ?? texts.first(where: { ($0.label ?? "").localizedCaseInsensitiveContains(label) && ($0.label ?? "").count > label.count }) else { return nil }
                    if let v = e.value, !v.isEmpty { return "\(label) = \(v)" }
                    let rest = (e.label ?? "").replacingOccurrences(of: label, with: "", options: .caseInsensitive).trimmingCharacters(in: CharacterSet(charactersIn: " :,"))
                    return rest.isEmpty ? nil : "\(label) = \(rest)"
                }
                if missing.isEmpty && values.count == routine.read.count { break }
                await sleep(seconds: 0.15)
            }
            if !missing.isEmpty {
                let why = "the end check did not pass: \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) not on screen"
                finish("ran, end check failed", stop: RoutineStop(step: routine.steps.count, why: why, at: Date()))
                return "run \"\(routine.name)\": \(outcome), but \(why); look at the screen below before going on"
            }
            if !routine.expect.isEmpty { outcome += ", end check passed (\(routine.expect.map { "\"\($0)\"" }.joined(separator: ", ")) on screen)" }
            if !values.isEmpty { outcome += "; read: " + values.joined(separator: "; ") }
            else if !routine.read.isEmpty { outcome += "; the values to read (\(routine.read.joined(separator: ", "))) were not found: read them from the screen below" }
        }
        finish("ok", stop: nil)
        routineRanWhole = true
        return "run \"\(routine.name)\": \(outcome)"
    }

    /// The number a run gives the element it found, for the one action it sends.
    static let runRef = 900_001

    static func replacingTarget(_ action: JSON, with ref: Int) -> JSON {
        guard case .object(var o) = action else { return action }
        for key in ["tap", "long_press"] {
            if o[key]?.string == "@" { o[key] = .number(Double(ref)) }
            else if case .object(var inner) = o[key], inner["ref"]?.string == "@" { inner["ref"] = .number(Double(ref)); o[key] = .object(inner) }
        }
        if o["ref"]?.string == "@" { o["ref"] = .number(Double(ref)) }
        return .object(o)
    }

    /// A new task: its recording starts empty.
    func beginRecording() {
        guard !handoffWaiting, intervention == nil else { return }
        trace = []
        traceHasUserGap = false
        routineRanWhole = false
    }

    /// The routines saved for the app in front, for the first look of a task (nil when none).
    func routinesLine() -> String? {
        guard let memory else { return nil }
        let app = lastForeground?.bundleID
        let all = memory.routines.filter { !$0.stale }
        guard !all.isEmpty else { return nil }
        let here = all.filter { $0.app == app }
        let shown = (here.isEmpty ? all : here).sorted { $0.updated > $1.updated }.prefix(6)
        let names = shown.map { "\"\($0.name)\"\($0.description.isEmpty ? "" : " (\($0.description.prefix(60)))")" }.joined(separator: ", ")
        return "routines\(here.isEmpty ? "" : " for this app"): \(names)\(all.count > shown.count ? ", and \(all.count - shown.count) more (routines {action: \"list\"})" : ""); do {run: \"name\"} repeats one in a single call"
    }
}

extension String {
    /// `{{name}}` replaced by the parameter's value.
    func replacingParams(_ params: [String: String]) -> String {
        var out = self
        for (k, v) in params { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }
}

// MARK: The routines tool

extension PokiCore {
    /// What a model should know at the start of a task about this phone's owner and saved routines:
    /// the notes, and the routines that fit `task` best. "" when nothing is saved.
    public static func memoryBrief(for task: String) -> String { RoutineStore.shared.brief(for: task) }

    static let routinesTool: JSON = [
        "name": "routines",
        "description": "The agent's memory on this phone, shared by every agent that drives it. Routines are saved paths through apps: the do actions of a task, each target kept as what it is (role and label), so do {run: \"name\"} replays it in one call, waits for each target, and stops cleanly at a screen that differs. Notes are short facts about the owner. action: list (routines and notes) | show (one routine's steps, name) | save (the do actions sent since this task began, as name, with description; expect: texts that must be on screen at the end, chosen from the last screen when left out; read: labels whose values a run reports) | edit (name; rename, description, expect, read, steps as JSON to replace them) | forget (name) | remember (text: a fact worth keeping, never a password) | forget_note (id or text) | export (the whole memory as JSON, to review or move) | import (data: such JSON; newer routines win). Save a routine after a task that worked and that someone may ask for again; save it again under the same name to fix one that stopped.",
        "inputSchema": ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "show", "save", "edit", "forget", "remember", "forget_note", "export", "import"]],
            "name": ["type": "string"], "description": ["type": "string"], "rename": ["type": "string"],
            "text": ["type": "string"], "data": ["type": "string"],
            "expect": ["type": "array", "items": ["type": "string"]], "read": ["type": "array", "items": ["type": "string"]],
            "steps": ["type": "string"],
        ], "required": ["action"], "additionalProperties": false],
    ]

    func routinesCall(_ args: JSON, session: String?) -> ToolResult {
        guard let store = computer.memory else { return ToolResult(text: "routines: no memory on this phone", jpeg: nil, isError: true) }
        let action = args["action"]?.string ?? "list"
        let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let by = session == nil ? "Poki" : (clientNames.value[session!].flatMap { $0.isEmpty ? nil : $0 } ?? "an MCP client")
        func fail(_ text: String) -> ToolResult { ToolResult(text: "routines \(action): \(text)", jpeg: nil, isError: true) }
        switch action {
        case "list":
            let routines = store.routines, notes = store.notes
            var lines = ["routines (\(routines.count)):"] + routines.map { "- \($0.summary)" }
            if routines.isEmpty { lines = ["routines: none saved yet. After a task that worked, routines {action: \"save\", name, description} keeps its steps so do {run: name} repeats them in one call."] }
            lines.append(notes.isEmpty ? "notes: none" : "notes (\(notes.count)):")
            lines += notes.map { "- [\($0.id)] \($0.text) (by \($0.by))" }
            if !computer.trace.isEmpty { lines.append("this task has \(computer.trace.count) recorded steps so far (save keeps them)") }
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
        case "show":
            guard let r = store.routine(named: name) else { return fail("no routine named \"\(name)\"") }
            var lines = [r.summary]
            for (i, s) in r.steps.enumerated() {
                lines.append("\(i + 1). \(s.action.serialized())\(s.target.map { " on \($0.describe) at [\(Int($0.x)), \(Int($0.y))]" } ?? "")\(s.app.map { " in \($0)" } ?? "")")
            }
            if !r.expect.isEmpty { lines.append("end check: " + r.expect.map { "\"\($0)\"" }.joined(separator: ", ")) }
            if !r.read.isEmpty { lines.append("reads: " + r.read.joined(separator: ", ")) }
            let compact = JSONEncoder(); compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; compact.dateEncodingStrategy = .iso8601
            let steps = (try? String(decoding: compact.encode(r.steps), as: UTF8.self)) ?? "[]"
            lines.append("steps as JSON (edit takes this shape): \(steps)")
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
        case "save":
            guard !name.isEmpty else { return fail("give the routine a name") }
            let expect = args["expect"]?.array?.compactMap(\.string)
            let read = args["read"]?.array?.compactMap(\.string) ?? store.routine(named: name)?.read ?? []
            let (routine, note) = computer.routine(named: name, description: args["description"]?.string ?? store.routine(named: name)?.description ?? "", read: read, expect: expect, by: by)
            guard let routine else { return fail(note) }
            let replacing = store.routine(named: name) != nil
            store.save(routine)
            return ToolResult(text: "routines: \(replacing ? "saved over" : "saved") \"\(routine.name)\" (\(routine.steps.count) steps\(routine.app.map { " in \($0)" } ?? "")\(routine.params.isEmpty ? "" : "; it types " + routine.params.keys.sorted().joined(separator: ", ") + ", which with: changes")\(routine.expect.isEmpty ? "" : "; end check: " + routine.expect.map { "\"\($0)\"" }.joined(separator: ", "))). do {run: \"\(routine.name)\"} repeats it.\(note.isEmpty ? "" : " Note: \(note).")", jpeg: nil)
        case "edit":
            guard store.routine(named: name) != nil else { return fail("no routine named \"\(name)\"") }
            var newSteps: [RoutineStep]?
            if let text = args["steps"]?.string {
                guard let steps = try? RoutineStore.decoder.decode([RoutineStep].self, from: Data(text.utf8)), !steps.isEmpty else { return fail("steps must be the JSON array show gives") }
                newSteps = steps
            }
            store.update(name) { r in
                if let d = args["description"]?.string { r.description = d }
                if let e = args["expect"]?.array { r.expect = e.compactMap(\.string) }
                if let e = args["read"]?.array { r.read = e.compactMap(\.string) }
                if let steps = newSteps { r.steps = steps; r.failuresInARow = 0; r.lastStop = nil }
                r.updated = Date()
            }
            if let rename = args["rename"]?.string, !rename.isEmpty { store.rename(name, to: rename) }
            return ToolResult(text: "routines: edited \"\(args["rename"]?.string ?? name)\"", jpeg: nil)
        case "forget":
            guard store.forget(name) else { return fail("no routine named \"\(name)\"") }
            return ToolResult(text: "routines: forgot \"\(name)\"", jpeg: nil)
        case "remember":
            let text = args["text"]?.string ?? ""
            guard let note = store.remember(text, by: by) else { return fail("give the text to remember") }
            return ToolResult(text: "routines: remembered [\(note.id)] \(note.text)", jpeg: nil)
        case "forget_note":
            guard store.forgetNote(args["text"]?.string ?? name) else { return fail("no such note") }
            return ToolResult(text: "routines: note forgotten", jpeg: nil)
        case "export":
            guard let data = try? store.exportData() else { return fail("could not be made") }
            return ToolResult(text: String(decoding: data, as: UTF8.self), jpeg: nil)
        case "import":
            guard let text = args["data"]?.string else { return fail("give data: the JSON export gives") }
            do {
                let summary = try store.importData(Data(text.utf8), by: by)
                    return ToolResult(text: "routines: \(summary)", jpeg: nil)
            } catch { return fail("\(error)") }
        default:
            return fail("unknown action; the actions are list, show, save, edit, forget, remember, forget_note, export, import")
        }
    }
}
