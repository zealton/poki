import Foundation

/// What a tool call answers: facts as text, a screenshot when there is one, and whether it failed.
public struct ToolResult: Sendable {
    public var text: String
    public var jpeg: Data?
    public var isError = false
}

/// A sent action failed: whether it may have reached the phone.
struct ActionFailure: Error, CustomStringConvertible {
    var message: String
    var delivery: Delivery
    var description: String { message }
}

/// The computer-use tools (look and do), ported from src/cua.mjs and src/cua-wda.mjs. One call does
/// some actions and then reads the screen once; the answer is facts only, and the model decides what
/// happened. Every step has a deadline, so a call always answers within `toolDeadline`.
final class Computer: @unchecked Sendable {
    let runner: Runner
    let host: CoreHost
    let config: CoreConfig
    let approvals: Approvals
    let emit: @Sendable (CoreEvent) -> Void
    /// The step the model handed to the owner (`{handoff: {kind, text}}`), until Done is reported once.
    let handoff = LockedBox<Handoff?>(nil)

    // Kept between calls; one tool call runs at a time (the gate in PokiCore), so no lock is needed.
    /// The numbers of the latest read. An element that is still there in the next read keeps its
    /// number, so a `do` can list only what changed.
    var refs: [Int: Element] = [:]
    var listed: [(ref: Int, element: Element)] = []
    var nextRef = 1
    /// Every element of the latest tree with a frame, listed or not (for what covers what).
    var lastAll: [Element] = []
    /// When the latest tree was read (a `wait_until: settled` takes a fresh one as its first sample).
    var lastTreeAt: Double?
    /// A swipe or drag went out that no tree read has shown yet: `scroll_to` reads before it swipes
    /// again, so a target cannot pass between two reads (the gym's row 250, scrolled past unread).
    var swipeUnread = false
    var lastForeground: Foreground?
    var size: ScreenSize?
    var lastPNG: Data?
    /// The latest failed step's error, worded for the app log: what the field held is named by case
    /// only (see recoverType). Core takes it after each call.
    let failureLog = LockedBox<String?>(nil)
    /// When `lastPNG` was taken (it stands in, marked stale, when a read gives no picture at all).
    var lastPNGAt: Double?
    /// How long the last look or do took inside the computer, for the MCP's own accounting.
    var lastCallTook: Double?
    var lastTree: String?
    var lastPicture: PictureSketch?
    /// Where the owner asked: the app in front at the task's first look or do, and the MCP session
    /// that made that call (nil from inside the app). The phone goes back there when the task ends.
    var origin: (app: Foreground, session: String?, lastCall: Double)?

    /// The element the last scroll_to found, so the read after it can give its number (it may be
    /// past the listing's limit: the gym's 1,507-element grid had its button at 1506).
    var scrollFound: Element?
    /// Shapes touches and typing after a person's (see `Humanize`); off sends the legacy schedules.
    var humanize: Humanize
    /// The element the last type went to and its text, so the read after it can say which number the
    /// field has now when the app replaced it (Settings' search field is a new element in search mode).
    var typedInto: (ref: Int, text: String)?
    /// How much of the picture changed in the latest read while the elements did not (nil when the
    /// elements changed too, or nothing did): a whole new picture over an unchanged tree is the old
    /// app's tree under the new app's screen (gym: Photos launched from Safari).
    var pictureOnlyShare: Double?

    /// The agent's memory, and this task's recorded steps (what routines {save} keeps).
    var memory: RoutineStore?
    var trace: [RecordedStep] = []
    var intervention: UserIntervention?
    var traceHasUserGap = false
    /// A routine ran whole in this task (the finish line does not offer to save it again).
    var routineRanWhole = false

    var lastElements: [Element] { listed.map(\.element) }
    var layout: Layout { Layout(all: lastAll, screen: size ?? ScreenSize(width: 10_000, height: 10_000)) }

    static let settle: [String: Double] = ["tap": 0.45, "type": 0.25, "key": 0.3, "swipe": 0.6, "drag": 0.35, "long_press": 0.4, "pinch": 0.6, "button": 0.7, "launch": 0.9, "scroll_to": 0.2, "wait": 0, "wait_until": 0]
    static let lineLimit = 120
    static let textLimit = 160

    init(runner: Runner, host: CoreHost, config: CoreConfig, approvals: Approvals, emit: @escaping @Sendable (CoreEvent) -> Void = { _ in }) {
        self.emit = emit
        self.runner = runner
        self.host = host
        self.config = config
        self.humanize = Humanize(enabled: config.humanize ?? Humanize.envEnabled)
        self.approvals = approvals
        self.memory = config.memory ?? RoutineStore.shared
    }

    // MARK: Reading and answering

    func screenSize(until: Double) async throws -> ScreenSize {
        if let size { return size }
        let s = try await runner.screenSize(timeout: max(0.5, min(3, until - now())))
        size = s
        return s
    }

    /// The screenshot's width: one pixel per screen point, so a point read off the picture is a point
    /// to tap.
    static func pictureWidth(_ screen: ScreenSize?) -> Int {
        guard let w = screen?.width, w >= 200, w <= 1400 else { return 300 }
        return Int(w.rounded())
    }

    /// Reads the screen and answers with the facts, whatever part of the read failed. `changes` lists
    /// only what changed since the read before (a `do`); `full` lists every element, as the tree has it.
    func readAndReply(until: Double, full: Bool, changes: Bool = false, did: [String] = [], error: String? = nil, extra: [String] = []) async -> ToolResult {
        let budget = max(0.8, min(config.readTimeout, until - now() - 0.2))
        let reading = await runner.read(timeout: budget, extra: max(0, min(4, until - now() - budget - 3)), format: config.treeFormat, callEnds: until)
        if size == nil { _ = try? await screenSize(until: now() + 1.5) }
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        var notes = reading.notes
        if let modal = modalOnly(reading.elements) { notes.append(modal) }
        if reading.png == nil && reading.elements.isEmpty {
            // Nothing came back: say what was sent and what the runner is doing, and nothing else.
            let state = host.runnerState()
            let did = did.map { $0.replacingOccurrences(of: "(sent,", with: "(sent, not confirmed: no read after it,") }
            // The numbers of the read before stand: nothing newer was read, and the model can act on
            // them or send the same action again (CI simulator: a type sent again after "nothing was
            // typed" was refused as stale because the refused call's read had failed).
            let kept = refs.isEmpty ? [] : ["the elements of the read before keep their numbers (nothing newer was read)"]
            // The picture of the read before, marked with its age, is better than none (gym: three
            // calls blind for 32 s while the runner restarted under load).
            var stale: Data?, staleNote: [String] = []
            if let old = lastPNG, let at = lastPNGAt, now() - at < 120, let jpeg = try? host.jpeg(fromPNG: old, width: Self.pictureWidth(size), quality: 0.6) {
                stale = jpeg
                staleNote = ["the screenshot is the one of the read before, \(Int((now() - at).rounded())) s old (no newer one came)"]
            }
            var lines: [String] = ["read: failed (\(notes.joined(separator: "; ")))", "runner: \(state.describe)"]
            lines += did.map { "did: \($0)" }
            if let error { lines.append("error: \(error)") }
            lines += extra + kept + staleNote
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: stale, isError: true)
        }
        let treeRead = !reading.elements.isEmpty || reading.notes.isEmpty
        let sameApp = reading.foreground?.bundleID == nil || reading.foreground?.bundleID == lastForeground?.bundleID
        lastForeground = reading.foreground ?? lastForeground
        if reading.png != nil { lastPNGAt = now() }
        lastPNG = reading.png ?? lastPNG

        // Whether the screen changed since the read before (the one the model saw last).
        let visible = listable(reading.elements, screen)
        let tree = visible.map { "\($0.key)@\($0.frame.described)" }.joined(separator: "\n")
        let picture = reading.png.map { PictureSketch(png: $0) }
        var changedLine: String?
        if changes, treeRead, let before = lastTree {
            let pictureChanged: Bool? = picture.flatMap { now in lastPicture.map { now.differs(from: $0) } }
            // Where and how much the picture moved, so a small change (an indicator fading, a badge)
            // can be told from a page coming in without looking.
            var where_ = ""
            if pictureChanged == true, let now = picture, let last = lastPicture, let change = now.change(from: last), size != nil {
                let box = [change.x * screen.width, change.y * screen.height, change.width * screen.width, change.height * screen.height].map { Int($0.rounded()) }
                where_ = ", in \(max(1, Int((change.share * 100).rounded()))) % of it, within [\(box.map(String.init).joined(separator: ", "))]"
            }
            pictureOnlyShare = nil
            if tree != before { changedLine = "screen_changed: true (the elements changed)" }
            else if pictureChanged == true {
                changedLine = "screen_changed: true (only the picture changed\(where_); the elements are the same)"
                if let now = picture, let last = lastPicture { pictureOnlyShare = now.change(from: last)?.share }
            }
            else { changedLine = "screen_changed: false (the elements\(pictureChanged == false ? " and the picture" : "") are the same as in the read before)" }
        }
        if treeRead { lastTree = tree }
        if let picture { lastPicture = picture }

        // What to list: the elements without repeats, and in a full read the text inside collapsed ones.
        var shown = treeRead ? lean(visible, full: full) : []
        let collapsed = Set(shown.filter { isCollapsed($0, in: reading.elements) }.map(\.node))
        // A web view with nothing of its page in the tree is read from the picture in every look.
        let emptyWeb = shown.contains { $0.type == "WebView" && collapsed.contains($0.node) }
        if full || emptyWeb, !collapsed.isEmpty, let png = reading.png, size != nil {
            let host = self.host
            // Vision's first pass on a CI simulator took 3.7 s (seen in the gym); the read gives it 4 s
            // when the call has them.
            let left = max(0.3, min(4, until - now() - 0.5))
            if let texts = (try? await withDeadline(left, "reading text from the picture", { await host.recognizeText(inPNG: png) })) ?? nil {
                // Each text goes right after the collapsed element it lies in, top to bottom.
                var inside: [Int: [Element]] = [:]
                let holders = shown.filter { collapsed.contains($0.node) }
                for t in texts {
                    let frame = Rect(x: t.box.x * screen.width, y: t.box.y * screen.height, width: t.box.width * screen.width, height: t.box.height * screen.height)
                    guard let holder = holders.last(where: { $0.frame.contains(frame.centre) }) else { continue }
                    inside[holder.node, default: []].append(Element(type: "Text", label: t.text, value: nil, identifier: nil, frame: frame, depth: holder.depth + 1, fromPicture: true))
                }
                shown = shown.flatMap { e in [e] + (inside[e.node] ?? []).sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) } }
            } else {
                notes.append("no text read from the picture (reading it did not finish within \(DeadlineExceeded.format(left)); call look again, or tap a point on the picture)")
            }
        }

        // No tree in time (a slow runner, a heavy keyboard): the text read from the picture stands in for
        // it, numbered and tappable at its centre, so the model is never left with only a picture.
        var pictureOnly = false
        if !treeRead, let png = reading.png, size != nil {
            let host = self.host
            // Vision's accurate model (needed for Chinese and Japanese) on a whole screenshot takes up to
            // a few seconds on a slow machine.
            let left = min(3.5, until - now() - 0.6)
            // Say why nothing came of it, so a slow or failing recogniser is told apart from an empty screen.
            var outcome = "no time left to read text from the picture"
            if left >= 0.3 {
                let began = now()
                do {
                    let texts = try await withDeadline(left, "reading text from the picture", { await host.recognizeText(inPNG: png) })
                    let ms = Int(((now() - began) * 1000).rounded())
                    if let texts, !texts.isEmpty {
                        shown = texts.map { t in
                            Element(type: "Text", label: t.text, value: nil, identifier: nil,
                                    frame: Rect(x: t.box.x * screen.width, y: t.box.y * screen.height, width: t.box.width * screen.width, height: t.box.height * screen.height),
                                    depth: 0, fromPicture: true)
                        }.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
                        pictureOnly = true
                    }
                    outcome = texts == nil ? "text could not be read from the picture; the picture is the screen now: tap points on it ([x, y]) or call look again" : "no text found in the picture (\(ms) ms); tap points on the picture ([x, y]) or call look again"
                } catch {
                    outcome = "reading text from the picture did not finish within \(Int(((now() - began) * 1000).rounded())) ms"
                }
            }
            if !pictureOnly { notes.append(outcome) }
        }

        // Numbers: an element still there keeps its number (same text and frame first, then same text).
        let prior = treeRead ? listed : []
        var exact: [String: [Int]] = [:], loose: [String: [Int]] = [:]
        for (r, e) in prior where !e.fromPicture {
            exact["\(e.key)@\(e.frame.described)", default: []].append(r)
            loose[e.key, default: []].append(r)
        }
        var used = Set<Int>()
        var assigned = [Int?](repeating: nil, count: shown.count)
        var moved = Set<Int>()
        for (i, e) in shown.enumerated() where !e.fromPicture {
            if let r = exact["\(e.key)@\(e.frame.described)"]?.first(where: { !used.contains($0) }) { assigned[i] = r; used.insert(r) }
        }
        for (i, e) in shown.enumerated() where !e.fromPicture && assigned[i] == nil {
            if let r = loose[e.key]?.first(where: { !used.contains($0) }) { assigned[i] = r; used.insert(r); moved.insert(r) }
        }
        // Another screen: numbering starts again.
        let fresh = prior.isEmpty || !sameApp || Double(used.count) < 0.3 * Double(max(1, shown.count))
        if fresh {
            assigned = [Int?](repeating: nil, count: shown.count)
            moved = []
            used = []
            nextRef = 1
        }
        for i in assigned.indices where assigned[i] == nil {
            assigned[i] = nextRef
            nextRef += 1
        }
        let gone = fresh ? [] : prior.filter { !used.contains($0.ref) && !$0.element.fromPicture }
        if treeRead {
            refs = [:]
            listed = []
            for (i, e) in shown.enumerated() {
                refs[assigned[i]!] = e
                listed.append((assigned[i]!, e))
            }
            lastAll = reading.elements
            lastTreeAt = now()
            swipeUnread = false
        } else if shown.isEmpty, !refs.isEmpty {
            // A picture but no tree and no text read from it: the numbers of the read before stand.
            notes.append("the elements of the read before keep their numbers (nothing newer was read)")
        } else {
            refs = [:]
            listed = []
            for (i, e) in shown.enumerated() { refs[assigned[i]!] = e }
        }

        func line(_ ref: Int, _ e: Element, _ mark: String) -> String {
            var text = e.text.isEmpty && e.type == "WebView" ? "web page (its parts are not in the tree yet: read again in a second)" : e.text
            if !full, text.count > Self.textLimit { text = "\(text.prefix(Self.textLimit - 10))… (+\(text.count - Self.textLimit + 10) characters)" }
            var tag = e.fromPicture ? " (read from the picture)" : collapsed.contains(e.node) ? " [collapsed]" : ""
            if tag.isEmpty, let size, coversScreenAlone(e, in: reading.elements, screen: size) {
                tag = " (one element covering \(Int((e.frame.width * e.frame.height * 100 / (size.width * size.height)).rounded())) % of the screen with no parts in the tree: tap a point on the picture, not its number)"
            }
            return "\(mark)\(ref) \(e.type) \"\(text)\" \(e.frame.described)\(tag)"
        }
        var body: [String] = []
        var heading: String
        let marks: [String] = shown.indices.map { i in
            let r = assigned[i]!
            if fresh { return " " }
            return used.contains(r) ? (moved.contains(r) ? "~" : " ") : "+"
        }
        if changes, !full, !fresh {
            let changed = shown.indices.filter { marks[$0] != " " }
            let same = shown.count - changed.count
            heading = changed.isEmpty
                ? "elements: none changed (\(shown.count) on screen keep their numbers)"
                : "elements (\(shown.count) on screen; only the changed are listed: + new, ~ moved; the \(same) others keep their numbers, full=true lists all):"
            body = changed.prefix(Self.lineLimit).map { line(assigned[$0]!, shown[$0], marks[$0]) }
        } else {
            heading = prior.isEmpty ? "elements (\(shown.count)):" : fresh ? "elements (\(shown.count); a new screen: numbered from 1 again, the numbers of the read before no longer apply):" : "elements (\(shown.count); + new since the last read, ~ moved):"
            let limit = full ? 1000 : Self.lineLimit
            body = shown.indices.prefix(limit).map { line(assigned[$0]!, shown[$0], marks[$0]) }
            if shown.count > limit {
                // What was left out, by type, so the model knows what it cannot see (the gym's grid
                // put the state button past the limit) and that scroll_to by text numbers any of them.
                var byType: [String: Int] = [:]
                for e in shown[limit...] { byType[e.type, default: 0] += 1 }
                let types = byType.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                body.append("… \(shown.count - limit) more not listed (\(types)); \(full ? "" : "full=true lists up to 1000; ")scroll_to with an element's text finds it and gives its number")
            }
        }
        if let wanted = scrollFound {
            // The element scroll_to found, with its number, listed whether or not the listing reached it.
            scrollFound = nil
            if let i = shown.firstIndex(where: { $0.key == wanted.key && $0.frame.described == wanted.frame.described }) ?? shown.firstIndex(where: { $0.key == wanted.key }) {
                body.append("found by scroll_to: \(line(assigned[i]!, shown[i], " ").trimmingCharacters(in: .whitespaces)) (tap \(assigned[i]!))")
            }
        }
        if pictureOnly { heading = "elements (\(shown.count), read from the picture because the element tree did not come in time; a number taps the text's centre):" }
        if !collapsed.isEmpty, !full { heading += "  ([collapsed] = one element whose parts are not in the tree; full=true adds the text read from the picture inside it, or tap a point on the screenshot)" }

        var jpeg: Data?
        let width = Self.pictureWidth(size)
        if let png = reading.png {
            do { jpeg = try host.jpeg(fromPNG: png, width: width, quality: 0.6) }
            catch { notes.append("screenshot not encoded: \(error)") }
        } else if let old = lastPNG, let at = lastPNGAt, now() - at < 120, let stale = try? host.jpeg(fromPNG: old, width: width, quality: 0.6) {
            // No picture from the runner or the host (a restart under load): the picture of the read
            // before, marked with its age, is better than none (gym: three calls blind for 32 s).
            jpeg = stale
            notes.append("the screenshot is the one of the read before, \(Int((now() - at).rounded())) s old (no newer one came); the elements, when read, are current")
        }
        let app = reading.foreground?.describe ?? "unknown"
        var header = ["app: \(app)   read: \(ISO8601DateFormatter().string(from: Date())) (\(reading.ms) ms)" + (notes.isEmpty ? "" : "   note: \(notes.joined(separator: "; "))")]
        if jpeg != nil { header.append(size != nil ? "screenshot: \(width) px wide, 1 px = 1 screen point (the same points as the frames and taps)" : "screenshot: \(width) px wide; screen size unknown") }
        header += did.map { "did: \($0)" }
        if let error { header.append("error: \(error)") }
        if let line = observeUserIntervention() { header.append(line) }
        if let line = handoffLine(clear: true) { header.append(line) }
        if let changedLine { header.append(changedLine) }
        header += extra
        header.append(heading)
        if let typed = typedInto, gone.contains(where: { $0.ref == typed.ref }), let i = shown.firstIndex(where: { Self.fieldTypes.contains($0.type) && ($0.value ?? "").contains(typed.text) }), let n = assigned[i] {
            body.append("the field typed into is now element \(n) (\(typed.ref) is gone: the app replaced the field)")
        }
        typedInto = nil
        let footer = gone.isEmpty ? [] : ["gone since the last read: " + gone.prefix(20).map { "\($0.ref) \($0.element.type) \"\($0.element.text.prefix(40))\"" }.joined(separator: ", ")]
        // An answer that carries the screen is not an error, whatever happened to the actions: the
        // `error:` line says what, and the model goes on from the picture and the elements. Only an
        // answer with nothing read, or with nothing sent at all, is one.
        return ToolResult(text: (header + body + footer).joined(separator: "\n"), jpeg: jpeg, isError: error != nil && did.isEmpty && jpeg == nil)
    }

    /// An answer with nothing done but the picture (served apart from WDA's queue), so a busy runner
    /// never leaves the model blind: it sees the screen and the next look is not an error.
    /// `isErrorWithoutPicture: false` for an answer that already says what to do next (wait for the
    /// runner): it is not an error even when the runner is too far gone to give the picture.
    func withPicture(_ text: String, timeout: Double, remember: Bool = true, isErrorWithoutPicture: Bool = true) async -> ToolResult {
        guard timeout > 0.3, let png = try? await runner.screenshot(timeout: min(3, timeout)) else {
            // The runner gives none: the host's own path to the screen, when it has one.
            if timeout > 0.3, let fallback = runner.screenshotFallback, let png = (try? await withDeadline(6, "the host's screenshot") { await fallback() }) ?? nil, let jpeg = try? host.jpeg(fromPNG: png, width: Self.pictureWidth(size), quality: 0.6) {
                return ToolResult(text: text + "\nscreenshot: the screen now, taken apart from the runner (nothing was sent)", jpeg: jpeg, isError: false)
            }
            return ToolResult(text: text + "\nscreenshot: none (the runner did not give one either)", jpeg: nil, isError: isErrorWithoutPicture)
        }
        if remember { lastPNG = png }
        let size = try? await screenSize(until: now() + 1)
        let jpeg = try? host.jpeg(fromPNG: png, width: Self.pictureWidth(size), quality: 0.6)
        return ToolResult(text: text + (jpeg == nil ? "" : "\nscreenshot: the screen now (nothing was sent)"), jpeg: jpeg, isError: jpeg == nil && isErrorWithoutPicture)
    }

    /// The `handoff:` line: a step handed to the owner that is waiting, or just done (reported once).
    func handoffLine(clear: Bool) -> String? {
        guard let h = handoff.value else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        if let done = h.done {
            if clear { handoff.value = nil }
            return "handoff: done at \(f.string(from: done)) (\(h.kind), \(Int(done.timeIntervalSince(h.requested))) s after \"\(h.text.prefix(80))\"); inputs are sent again, go on with the task"
        }
        if h.ownerOnly {
            return "handoff: waiting for the owner to finish editing and tap Done; the agent cannot dismiss this pause. Do not replay unfinished typing. Read the edited field after Done before planning another action."
        }
        return "handoff: waiting (\(h.kind)) since \(f.string(from: h.requested)) (\(Int(Date().timeIntervalSince(h.requested))) s): \"\(h.text.prefix(80))\"; no input is sent until the owner taps Done on the phone or you send {handoff: false}; keep polling with look, or {wait_until: {handoff_done: true, ms: 10000}}"
    }

    var handoffWaiting: Bool { handoff.value.map { $0.done == nil } ?? false }

    func handoffDone(id: String) {
        let ended = handoff.update { r -> Bool in
            guard var current = r, current.id == id, current.done == nil else { return false }
            current.done = Date(); r = current; return true
        }
        if ended { emit(.handoffEnded(id: id, how: "done")) }
    }

    func look(full: Bool, session: String? = nil) async -> ToolResult {
        let started = now()
        defer { lastCallTook = now() - started }
        return await lookNow(full: full, session: session)
    }

    func lookNow(full: Bool, session: String? = nil) async -> ToolResult {
        let until = now() + config.toolDeadline
        if let blocked = await waitForRunner(until: until) { return blocked }
        let begins = beginsTask()
        if begins { beginRecording() }
        async let locked = isLocked()
        var result = restartNote(await readAndReply(until: until, full: full))
        if begins, let app = lastForeground { origin = (app, session, now()) } else { origin?.lastCall = now() }
        if begins, let line = routinesLine() { result.text += "\n" + line }
        guard await locked else { return result }
        var lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert("screen: locked (the owner has to unlock the phone before anything can be done)", at: min(1, lines.count))
        return ToolResult(text: lines.joined(separator: "\n"), jpeg: result.jpeg, isError: result.isError)
    }

    /// The answer with the reason for a restart this side made, reported once: the model learns why
    /// its last calls got nothing and that the runner is a fresh one (its numbers start over).
    func restartNote(_ result: ToolResult) -> ToolResult {
        guard let why = runner.lastRestart.update({ r -> String? in defer { r = nil }; return r }) else { return result }
        return ToolResult(text: "runner: \(why); this is the new runner\n" + result.text, jpeg: result.jpeg, isError: result.isError)
    }

    /// WDA's lock state, without a session; unknown counts as unlocked (a failed read must not block).
    func isLocked() async -> Bool {
        (try? await runner.raw("GET", "/wda/locked", timeout: 1, countsAsMiss: false))?.bool ?? false
    }

    /// The app stops the runner when no agent is using the phone, and asking for its state wakes it.
    /// While it is starting, the call waits for it (every 250 ms, at most `runnerWait`, within the
    /// call's deadline) and then goes on; a failed runner is answered at once, with its fix.
    func waitForRunner(until: Double) async -> ToolResult? {
        var state = host.runnerState()
        // A runner seen starting is a new process: what the last one was finishing, and its settings,
        // went with it (seen in the gym: after a restart the first call still waited on a request the
        // old runner had been serving).
        var restarted = false
        if case .starting = state { restarted = true }
        let waitUntil = min(now() + config.runnerWait, until - config.readTimeout - 1)
        while case .starting = state, now() < waitUntil {
            await sleep(seconds: 0.25)
            state = host.runnerState()
        }
        if restarted { runner.forgetRunner() }
        guard !state.isRunning else { return nil }
        let why = runner.lastRestart.value.map { "runner: \($0)\n" } ?? ""
        // A runner that is starting (the first start after a restart can wait for the owner's
        // password or Developer Mode on the phone) is not an error: the model keeps polling look
        // or status every few seconds and goes on when it is up; the owner is told on the phone.
        if case .failed = state {
            return ToolResult(text: "runner: \(state.describe)\nNothing was sent. Fix it on the phone, then call look again.", jpeg: nil, isError: true)
        }
        return ToolResult(text: "\(why)runner: \(state.describe)\nNothing was sent. It is still starting (the first start after a restart can wait for the owner to enter their password on the phone, which the phone asks them for); call look or status again every few seconds, and go on with the task when it answers with the screen.", jpeg: nil, isError: false)
    }

    // MARK: do

    /// How long to hold for the owner: `approvalWait`, but a relay stops waiting for its caller at
    /// `answerBy`, so the hold ends early enough for the answer (a read of the screen, and a margin)
    /// to get there first. The request stays open: the owner approves, and the same `do` sent again runs.
    func approvalHold(answerBy: Double?) -> Double {
        guard let answerBy else { return config.approvalWait }
        return max(0, min(config.approvalWait, answerBy - now() - config.readTimeout - Self.relayMargin))
    }
    static let relayMargin = 2.0

    /// What one action may take (`run` holds each to it). A launch gets 9 s; a fresh one (the app
    /// ended first, up to 6 s on its own) 14 s. A type is a tap, a wait for the focus and the keys (and
    /// a wait for a busy runner): 9 s. A wait_until gets the time it asks for (up to 10 s) plus a read:
    /// 8000 ms asked became 6000 under the action cap (gym, an app relaunch under the wait).
    static func nativeTypingBudget(_ text: String) -> Double {
        // Each word needs fresh candidate and field reads. Keep a finite ceiling;
        // an uncertain or timed-out edit is never automatically replayed.
        min(300, max(60, 45 + Double(text.count) * 3))
    }

    func toolBudget(_ actions: [JSON]) -> Double {
        guard runner.verifiesNativeTyping, actions.contains(where: { $0["type"] != nil }) else { return config.toolDeadline }
        return max(config.toolDeadline, min(300, actions.reduce(0) { $0 + actionCap($1) }) + config.readTimeout + 2)
    }

    func actionCap(_ action: JSON) -> Double {
        // A routine's steps each have their own time inside it; the run as a whole has the call's.
        if action["run"] != nil { return max(config.actionCap, config.toolDeadline - config.readTimeout - 1) }
        if action["launch"] != nil { return max(config.actionCap, action["launch"]?["fresh"]?.bool == true ? 14 : 9) }
        if action["scroll_to"] != nil { return max(config.actionCap, Self.scrollCap) }
        if action["type"] != nil { return max(config.actionCap, runner.verifiesNativeTyping ? Self.nativeTypingBudget(action["type"]?.text ?? "") : 9) }
        if action["wait_until"] != nil { return max(config.actionCap, min(10, max(0.2, (action["wait_until"]?["ms"]?.double ?? 3000) / 1000)) + 1.5) }
        return config.actionCap
    }

    /// The most `actions`, the pause after the last and the read of the screen can take once they
    /// start, each action within its own cap. The call's deadline (`until`) may bound it sooner.
    func timeToFinish(_ actions: [JSON], until: Double) -> Double {
        let longestPause = Self.settle.values.max() ?? 1
        return min(max(0, until - now()), actions.reduce(0) { $0 + actionCap($1) } + longestPause + config.readTimeout)
    }

    func act(actions: [JSON], full: Bool, finish: Bool = false, session: String? = nil, answerBy: Double? = nil) async -> ToolResult {
        restartNote(await actNow(actions: actions, full: full, finish: finish, session: session, answerBy: answerBy))
    }

    func actNow(actions: [JSON], full: Bool, finish: Bool = false, session: String? = nil, answerBy: Double? = nil) async -> ToolResult {
        if intervention != nil, handoff.value?.done != nil {
            var result = await readAndReply(until: now() + config.toolDeadline, full: true)
            result.text += "\nnot_sent: the owner finished editing. Read this fresh state and replan; the queued actions were not sent."
            return result
        }
        scrollFound = nil
        typedInto = nil
        var started = now()
        let callStarted = started
        var approvalWaited = 0.0
        var until = started + toolBudget(actions)
        if let blocked = await waitForRunner(until: until) { return blocked }
        // The app the owner is in before anything is sent: the read before may be another task's.
        if beginsTask() {
            beginRecording()
            if let front = try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1.5), let bundle = front["bundleId"]?.string {
                origin = (Foreground(bundleID: bundle, name: front["name"]?.string), session, now())
            }
        } else {
            origin?.lastCall = now()
        }

        // A runner still finishing a request this side gave up on gets nothing new: what is sent now
        // would wait its turn and run late, after the model had moved on.
        if await !runner.waitUntilFree(timeout: min(config.actionCap, until - now() - config.readTimeout - 0.5)), let busy = runner.busyWith {
            return await withPicture("not_sent: the runner is still finishing an earlier \(busy); nothing was sent. Call look again in a few seconds; it answers when the runner is through, or after the restart.", timeout: until - now() - 0.5, isErrorWithoutPicture: false)
        }

        // A locked phone takes no input but the buttons; the owner unlocks it.
        // While a step is handed to the owner, nothing is sent (they may be typing a password):
        // the model sees the screen, waits, or takes the step back.
        let harmless = actions.allSatisfy { $0["wait"] != nil || $0["wait_until"] != nil || $0["handoff"] != nil }
        if (!harmless || finish), handoffWaiting, let h = handoff.value {
            if h.ownerOnly {
                return await withPicture("not_sent: the owner took over typing. Wait for them to tap Done; agents cannot dismiss this pause. Do not replay the unfinished text.", timeout: until - now() - 0.5, isErrorWithoutPicture: false)
            }
            return await withPicture("not_sent: a step is handed to the owner (\(h.kind): \"\(h.text.prefix(80))\"), so no input is sent until they tap Done on the phone or you send {handoff: false}. Keep polling with look, or {wait_until: {handoff_done: true, ms: 10000}}.", timeout: until - now() - 0.5, isErrorWithoutPicture: false)
        }
        let onlyButtons = actions.allSatisfy { $0["button"] != nil || $0["wait"] != nil }
        if !onlyButtons, await isLocked() {
            return ToolResult(text: "screen: locked. Nothing was sent. The owner has to unlock the phone; call look once they have.", jpeg: nil, isError: true)
        }

        // A number that is not in the latest read is refused before anything is sent.
        let stale = Set(actions.flatMap(Self.refs(in:))).filter { refs[$0] == nil }.sorted()
        if !stale.isEmpty {
            return await readAndReply(until: until, full: true, error: "element \(stale.map(String.init).joined(separator: ", ")) is not in the latest read; nothing was sent. The current elements are below.")
        }

        // The approval card is in Poki: no input lands there, and the request waiting stays for the owner.
        if landsInPoki(actions) {
            return ToolResult(text: "not_sent: \(CoreConfig.ownAppRefusal). Nothing was sent. Leave Poki first ({button: \"home\"} or {launch: \"bundle id\"}).", jpeg: nil, isError: true)
        }

        if config.sensitive.enabled {
            var scan = SensitiveScan(front: lastForeground, secureOnScreen: lastElements.contains(where: \.isSecure))
            for (at, action) in actions.enumerated() {
                if scan.moved, let point = action["tap"] ?? action["long_press"], point.array != nil || point["x"] != nil {
                    var result = await actNow(actions: Array(actions[..<at]), full: full, finish: false, session: session, answerBy: answerBy)
                    result.text += "\nnot_sent from action \(at + 1): the screen may have changed. Choose the remaining actions from the fresh screen above and send them in a new do call. Do not repeat the actions already sent."
                    return result
                }
                if sensitive(action, &scan) != nil { break }
            }
        }

        // The runner's start and the checks above are not the actions' time (seen on the phone: a
        // launch sent while the runner was starting had its 9 s used up before it went). The call's
        // backstop allows `runnerWait` for that, so the shift stops there: a runner that was waited
        // for and then busy for the action cap on top (the soak, call 111) must not push the
        // actions past the backstop, which answers with nothing.
        let prepared = now()
        until += min(prepared - started, config.runnerWait)
        started = prepared
        let before = lastForeground
        var extra: [String] = []

        // Approval: from the first action that needs it, nothing is sent until the owner approves it
        // on the phone. The actions before it are plain and go first (seen on the phone: a last
        // selection tap held back with the Delete after it was never made, so the Delete, once
        // approved, would have missed it).
        var did: [String] = []
        var error: String?
        var lastKind: String?
        var toRun = actions
        var approvedNote: String?
        let sensitive = firstSensitive(actions)
        // Any other actions withdraw a pending request: nothing the automation does can approve it.
        if let pending = approvals.pending, pending.fingerprint != sensitive.map({ JSON.array(Array(actions[$0.at...])).serialized() }) {
            approvals.withdraw(id: pending.id)
        }
        if let (at, reason) = sensitive {
            let tail = Array(actions[at...])
            let fingerprint = JSON.array(tail).serialized()
            if approvals.consumeGrant(fingerprint: fingerprint) != nil {
                approvedNote = "approval: approved on the phone (\(reason))"
            } else {
                if at > 0 {
                    (did, error, lastKind) = await run(Array(actions[..<at]), started: started, until: until)
                    if error != nil {
                        return await readAndReply(until: until, full: full, changes: true, did: did, error: error, extra: ["action \(at + 1) and the actions after it were not sent (they would have needed the owner's approval: \(reason))"])
                    }
                }
                let approval = approvals.pending.flatMap { $0.fingerprint == fingerprint ? $0 : nil }
                    ?? approvals.request(app: lastForeground?.describe ?? "unknown", summary: labels(tail), reason: reason, fingerprint: fingerprint)
                // The time the owner takes is not the actions' time: the clock starts again after it.
                let asked = now()
                let outcome = await approvals.wait(id: approval.id, seconds: approvalHold(answerBy: answerBy))
                let waited = now() - asked
                until += waited
                started += waited
                approvalWaited += waited
                // The caller gave up while the owner was being waited for (the relay sent `cancel`): the
                // model will send these actions again, so nothing is sent for this call, whatever the owner does.
                if Task.isCancelled {
                    return ToolResult(text: "cancelled: the caller stopped waiting before the owner answered; nothing was sent from action \(at + 1).", jpeg: nil, isError: true)
                }
                // The owner's approval can open Poki: the app comes back before anything is sent into Poki.
                // Nothing of the owner's can have done that while the request is still unanswered, and
                // the time is the answer's.
                if outcome != nil, let back = await bringBack(from: before, why: "after the approval", check: true) { extra.append(back) }
                let sentFirst = at > 0 ? " Actions 1 to \(at) were sent (below)." : ""
                let again = at > 0 ? "send action \(at + 1)\(tail.count > 1 ? " to \(actions.count)" : "") again, on their own" : "send the same actions again"
                switch outcome {
                case .approved? where answerBy.map({ now() + timeToFinish(tail, until: until) + Self.relayMargin > $0 }) == true:
                    // Too late for the relay: the actions would run after it answered its caller with a 504, and
                    // the model would send them again. The approval stays; the same actions sent again run at once.
                    return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): approval_required (id \(approval.id)): \(reason). The owner approved on the phone, but too late for this call to send the actions and read the screen before the relay gives up on it.\(sentFirst) The approval is kept: \(again) and they run at once (within \(Int(approvals.lifetime / 60)) minutes).")
                case .approved?:
                    guard approvals.consumeGrant(fingerprint: fingerprint) != nil else {
                        return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): approval_required (id \(approval.id)): \(reason). The approval went to another call with the same actions, so nothing was sent from this one.\(sentFirst) To run them, \(again) and ask again.")
                    }
                    approvedNote = "approval: approved on the phone after \(Int(waited.rounded())) s (\(reason))"
                    toRun = tail
                case .declined?:
                    return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): the owner declined on the phone (\(reason)).\(sentFirst)")
                case .expired?:
                    return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): the approval request ended unanswered (\(reason)).\(sentFirst)")
                case nil:
                    return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): approval_required (id \(approval.id)): \(reason). The owner was asked on the phone.\(sentFirst) When they approve, \(again) (within \(Int(approvals.lifetime / 60)) minutes); other actions withdraw the request.")
                }
            }
        }

        let actionsStarted = now()
        let (moreDid, moreError, moreKind) = await run(toRun, started: started, until: until, numberedFrom: actions.count - toRun.count)
        let actionsTook = now() - actionsStarted
        did += moreDid
        error = moreError
        lastKind = moreKind ?? lastKind
        if let lastKind {
            let pause = min(Self.settle[lastKind] ?? 0.4, max(0, until - now() - config.readTimeout - 0.3))
            if pause > 0.01 {
                await sleep(seconds: pause)
                did.append("paused \(Int((pause * 1000).rounded())) ms before reading")
            }
        }
        let readStarted = now()
        // What the model saw last, so a read made again in this call still compares with it.
        let seenTree = lastTree, seenPicture = lastPicture
        var result = await readAndReply(until: until, full: full, changes: true, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra)
        // The read shows Poki in front where another app was being worked in: a tap at the top of
        // the screen landed on Poki's Live Activity in the Dynamic Island. The app comes back and
        // the read is made again, so the model never sees (or acts in) Poki's own screen.
        if config.isPoki(lastForeground), !toRun.contains(where: { $0["launch"] != nil }), until - now() > config.readTimeout + 1,
           let back = await bringBack(from: before, why: "after the actions (a tap near the top of the screen lands on Poki's Live Activity in the Dynamic Island)", check: false) {
            result = await readAndReply(until: until, full: full, changes: true, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra + [back])
        }
        // After a launch the runner's tree can still be the old app's while the picture is the new
        // app's (gym: Photos launched from Safari answered Safari's whole tree under Photos' screen,
        // twice). The read is made again, within the call, until the launched app is in front, or
        // when the whole picture changed over an unchanged tree.
        let launched = toRun.compactMap { $0["launch"].flatMap { $0.string ?? $0["bundle"]?.string } }.last
        var rereads = 0
        // Up to six re-reads: a cold launch on the simulator (Photos from Safari) had the old app in
        // front past the third re-read at 5.8 s (gym finding 39); the action's time bounds them.
        while rereads < 6, until - now() > config.readTimeout + 1 {
            let notYetInFront = launched.map { lastForeground?.bundleID != nil && lastForeground?.bundleID != $0 } ?? false
            let stalePicture = (pictureOnlyShare ?? 0) >= 0.9
            guard notYetInFront || stalePicture else { break }
            // A system alert over the launched app (a permission prompt): no re-read brings the app
            // in front; the answer says so, so the model answers the alert first.
            if notYetInFront, lastForeground?.bundleID == "com.apple.springboard", let alert = alertOnScreen() {
                result.text += "\na system alert is in front (\(alert)); the launched app is behind it: answer the alert first"
                break
            }
            rereads += 1
            await sleep(seconds: 0.4)
            let why = notYetInFront ? "\(launched!) was not in front yet" : "the whole picture had changed while the elements had not (an app's tree can lag its screen)"
            lastTree = seenTree
            lastPicture = seenPicture
            result = await readAndReply(until: until, full: full, changes: true, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra + ["the screen was read again (\(rereads)): \(why)"])
        }
        // The app this call opened answers no tree because its process has no accessibility server
        // (on the phone, WeChat for half an hour: "Error getting main window kAXErrorServerNotFound",
        // while Settings and Poki read; the same WeChat process read fine later). It is opened once
        // more from a fresh start, which brings up a process with one, and read again. Only an app the
        // call itself brought forward: ending one the owner was in would lose their place.
        let cameForward = launched ?? (lastForeground?.bundleID != before?.bundleID ? lastForeground?.bundleID : nil)
        if let app = cameForward, lastForeground?.bundleID == app, !config.isPoki(lastForeground), app != "com.apple.springboard",
           result.text.contains("kAXErrorServerNotFound"), until - now() > config.readTimeout + 4 {
            var how = "it was opened again from a fresh start"
            do {
                _ = try await runner.call("POST", "/wda/apps/terminate", ["bundleId": .string(app)], timeout: 6, countsAsMiss: false)
                _ = try await runner.call("POST", "/wda/apps/launch", ["bundleId": .string(app)], timeout: max(3, min(10, until - now() - config.readTimeout - 0.5)))
            } catch {
                how = "opening it again from a fresh start did not answer (\(error))"
            }
            await sleep(seconds: 0.4)
            lastTree = seenTree
            lastPicture = seenPicture
            result = await readAndReply(until: until, full: full, changes: true, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra + ["\(app) answered no element tree (no accessibility server in its process: kAXErrorServerNotFound); \(how), so its earlier page is gone"])
        }
        // A call that took far longer than its parts says where the time went (gym: a wait_until
        // whose parts said 5 s answered after 29.8 s).
        let total = now() - callStarted
        let readTook = now() - readStarted
        let parts = (prepared - callStarted) + actionsTook + readTook + approvalWaited
        lastCallTook = total
        if total >= 8 || total - parts > 2 {
            result.text += "\ntook: \(Self.seconds(total)) s in all: \(Self.seconds(prepared - callStarted)) s before the actions (runner start, busy wait, lock check), \(Self.seconds(actionsTook)) s actions, \(Self.seconds(readTook)) s read\(approvalWaited > 0 ? ", \(Self.seconds(approvalWaited)) s the owner's approval" : "")\(total - parts > 2 ? ", \(Self.seconds(total - parts)) s elsewhere" : "")"
        }
        // The read above is the work's last screen; the owner then sees their own app again.
        if finish, error == nil {
            let line = await returnToOrigin() ?? "finish: the app this task began in is not known, so the phone stays here"
            var lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines.insert(line, at: min(1, lines.count))
            if trace.count >= 2, !routineRanWhole, !traceHasUserGap {
                lines.append("learn: this task took \(trace.count) recorded steps; if it worked and may be asked for again, routines {action: \"save\", name, description} keeps them so do {run: name} repeats them in one call next time")
            }
            result.text = lines.joined(separator: "\n")
        }
        return result
    }

    /// A call with no task open, or after `taskGap` without one, begins a task.
    func beginsTask() -> Bool { origin.map { now() - $0.lastCall > config.taskGap } ?? true }

    /// Ends the task: the app it began in comes to the front again (the home screen by the Home
    /// button), and nothing is sent when it is in front already. nil when no task was open.
    func returnToOrigin() async -> String? {
        guard let task = origin else { return nil }
        origin = nil
        if let takeover = handoff.value, takeover.ownerOnly, takeover.done == nil {
            return "finish: the owner took over typing, so the current app stays in front"
        }
        guard let bundle = task.app.bundleID else { return nil }
        let front = try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1.5)
        if front?["bundleId"]?.string == bundle { return "finish: \(task.app.describe), where the task began, is in front" }
        do {
            if bundle == "com.apple.springboard" {
                // WDA serves the Home button only outside a session.
                _ = try await runner.raw("POST", "/wda/homescreen", [:], timeout: 8, countsAsMiss: false)
            } else {
                _ = try await runner.call("POST", "/wda/apps/activate", ["bundleId": .string(bundle)], timeout: 4)
            }
            // The answer comes while the switch still animates (seen on the simulator: a look right
            // after found the App Switcher), so the app is watched until it is in front.
            let until = now() + 3
            while now() < until {
                if (try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1))?["bundleId"]?.string == bundle {
                    return "finish: back in \(task.app.describe), where the task began"
                }
                await sleep(seconds: 0.25)
            }
            return "finish: \(task.app.describe), where the task began, was brought back but is not in front after 3 s"
        } catch {
            return "finish: \(task.app.describe), where the task began, could not be brought back (\(error))"
        }
    }

    static func seconds(_ t: Double) -> String { String(format: "%.1f", max(0, t)) }

    /// An alert in the latest tree, as its text and buttons ("Just a moment: Not now, Allow"), or nil.
    /// The tree holds an alert or a sheet and nothing named outside it: the in-process path snapshots
    /// the front layer alone (the alert's accessibility is modal), where WebDriverAgent's source keeps
    /// the screen behind. Said, so the model does not take the screen for gone (gym, in-process: a
    /// look under an alert listed the alert's three elements and nothing of the app).
    func modalOnly(_ all: [Element]) -> String? {
        guard let modal = all.first(where: { ($0.type == "Alert" || $0.type == "Sheet") && !$0.fromPicture }) else { return nil }
        let outside = all.filter { !$0.text.isEmpty && !modal.contains($0) && $0.node != modal.node && !Self.containers.contains($0.type) }
        guard outside.isEmpty else { return nil }
        return "the tree lists the \(modal.type == "Alert" ? "alert" : "sheet") only, not the screen behind it (it is still there, under the picture's dimming): answer or dismiss it to list the screen again"
    }

    func alertOnScreen() -> String? {
        guard let alert = lastAll.first(where: { $0.type == "Alert" && !$0.fromPicture }) else { return nil }
        let inside = lastAll.filter { alert.contains($0) }
        let text = inside.first { $0.type == "StaticText" && !$0.text.isEmpty }?.text.prefix(60)
        let buttons = inside.filter { $0.type == "Button" }.prefix(4).map { "\($0.text.prefix(30))" }.joined(separator: ", ")
        return "\(text.map { "\"\($0)\"" } ?? "an alert")\(buttons.isEmpty ? "" : ": \(buttons)")"
    }

    /// When Poki itself is in front although the model was working in another app, that app is
    /// activated again, and the line says so. nil when nothing had to be done.
    func bringBack(from before: Foreground?, why: String, check: Bool) async -> String? {
        guard let app = before?.bundleID, !config.isPoki(before) else { return nil }
        if check {
            guard let front = try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1.5), config.isPoki(Foreground(bundleID: front["bundleId"]?.string, name: nil)) else { return nil }
        }
        do {
            _ = try await runner.call("POST", "/wda/apps/activate", ["bundleId": .string(app)], timeout: 4)
            return "note: Poki was in front \(why); \(before?.describe ?? app) was brought back. Nothing was sent into Poki."
        } catch {
            return "note: Poki was in front \(why), and \(before?.describe ?? app) could not be brought back (\(error)). Launch it, or ask the owner."
        }
    }

    /// The actions, in order, each within its own action time (`actionCap` from when it starts; a
    /// launch gets 9 s, the time XCTest's launch handshake takes on the phone) and the call's
    /// deadline. Stops at the first that fails.
    func run(_ actions: [JSON], started: Double, until: Double, numberedFrom offset: Int = 0) async -> (did: [String], error: String?, lastKind: String?) {
        var did: [String] = []
        var error: String?
        var logError: String?
        var lastKind: String?
        defer { if let line = logError ?? error { failureLog.value = line } }
        for (i, action) in actions.enumerated() {
            let index = offset + i
            let cap = actionCap(action)
            let actionsUntil = min(until - config.readTimeout - 0.5, now() + cap)
            let left = actionsUntil - now()
            if left < 0.3 {
                error = "stopped before action \(index + 1): the call's time ran out (\(Int(toolBudget(actions))) s for all the actions and the read); nothing more was sent"
                break
            }
            let began = now()
            let givenUp = runner.actionsGivenUp.value
            let recorded = recordable(action)
            do {
                let (kind, text) = try await withDeadline(left, "action \(index + 1)") { [self] in try await perform(action, until: actionsUntil) }
                if let recorded { trace.append(recorded) }
                lastKind = kind
                did.append("\(text) (sent, \(Int(((now() - began) * 1000).rounded())) ms)")
            } catch is CancellationError {
                did.append("\(action.serialized()) (unknown: cancelled)")
                error = "cancelled at action \(index + 1)"
                break
            } catch let failure {
                if let takeover = failure as? RunnerError, takeover.code == "poki user takeover" {
                    let h = Handoff(id: UUID().uuidString, kind: "other",
                        text: "You took over typing. Edit the text, then tap Done when Poki may continue. The unfinished text will not be replayed.",
                        requested: Date(), ownerOnly: true)
                    handoff.value = h
                    beginUserIntervention(h)
                    emit(.handoffRequested(id: h.id, kind: h.kind, text: h.text, app: lastForeground?.describe))
                }
                let delivery: Delivery
                var why = "\(failure)"
                switch failure {
                case let e as ActionFailure: delivery = e.delivery
                case let e as RunnerError: delivery = e.delivery
                case is DeadlineExceeded where action["wait_until"] != nil || action["wait"] != nil:
                    // A wait only reads: nothing was sent, whatever the time it ran out of.
                    delivery = .notSent
                    why += " (it only reads the screen; nothing was sent)"
                case is DeadlineExceeded where !runner.hasSession && runner.actionsGivenUp.value == givenUp:
                    // The time ran out while a session was still being opened: nothing reached the phone.
                    delivery = .notSent
                    why += runner.busyWith.map { "; the runner is still finishing an earlier \($0)" } ?? "; no session was open yet"
                default: delivery = .unknown
                }
                // A type that failed or timed out may still have landed, or can be sent once more: what
                // the field holds decides (see recoverType). Every other action that may have been
                // delivered is never sent again by us.
                var recoveryNote = "", recoveryLog = ""
                if !runner.verifiesNativeTyping, let text = action["type"]?.text, action["via"]?.string != "paste", !(failure is ActionFailure), failure is RunnerError || failure is DeadlineExceeded {
                    let recovered = await recoverType(action, text: text, why: why, until: until - config.readTimeout - 0.5)
                    if let done = recovered.done {
                        lastKind = "type"
                        did.append("\(done) (sent, \(Int(((now() - began) * 1000).rounded())) ms)")
                        continue
                    }
                    recoveryNote = recovered.note.isEmpty ? "" : "; \(recovered.note)"
                    recoveryLog = recovered.logNote.isEmpty ? "" : "; \(recovered.logNote)"
                }
                did.append("\(action.serialized()) (\(delivery.rawValue), \(Int(((now() - began) * 1000).rounded())) ms)")
                // Nothing after a failed action is sent.
                let head = "action \(index + 1) \(delivery == .unknown ? "may have been delivered" : "was not sent"): \(why)"
                let tail = i + 1 < actions.count ? "; the actions after it were not sent" : ""
                error = head + recoveryNote + tail
                logError = head + recoveryLog + tail
                break
            }
        }
        return (did, error, lastKind)
    }

    /// After a type that failed or timed out: what the focused field holds says what happened, so the
    /// text is neither lost nor typed twice. The text is all there (the runner answered late or with an
    /// error after typing): it counts as typed. The field is empty (a placeholder is nothing) or being
    /// cleared, so a second try cannot double it: sent once more. Anything else, another person's text,
    /// a half-typed or unreadable field: not sent again. `done` is the step's text when the text is in
    /// the field. `note` goes on the answer to the model and may quote the field; `logNote` goes on the
    /// line the app log keeps and only ever says which case it was, never what the field holds.
    ///
    /// The real runner answers an empty field with its placeholder, so a value is read as text first
    /// (the value is the target text, or holds it) and as a placeholder second. A value equal to the
    /// placeholder is empty unless the text begins with it: then a first try may have landed that
    /// much, and the field is left alone rather than risk typing the text twice.
    func recoverType(_ action: JSON, text: String, why: String, until: Double) async -> (done: String?, note: String, logNote: String) {
        guard until - now() > 1.2 else { return (nil, "", "no time left to check the field") }
        let hidden = describe(action).hasSuffix("(hidden)")
        func shown(_ value: String) -> String { hidden ? "\(value.count) characters" : "\"\(value.count > 200 ? String(value.prefix(190)) + "…" : value)\"" }
        func typed(_ held: String) -> (done: String?, note: String, logNote: String) {
            ("\(describe(action)) (typed); the runner answered late or with an error, and the field now reads \(shown(held))", "", "")
        }
        enum Doubt { case none, mayBeThePlaceholder, placeholderUnread }
        var value = ""
        var doubt = Doubt.none
        switch await readField(until: until) {
        case .unreadable:
            return (nil, "the field could not be read afterwards, so the text was not typed again", "field unreadable, not typed again")
        case .empty:
            break
        case .text(let held, let id):
            // Exactly the text: typed, or the placeholder is this very text. Either way it is not typed twice.
            if held == text { return typed(held) }
            switch await placeholder(ofField: id, until: until) {
            case .text(let shownPlaceholder) where shownPlaceholder == held:
                if text.hasPrefix(held) { value = held; doubt = .mayBeThePlaceholder }
            case let known:
                if held.contains(text) { return typed(held) }
                value = held
                if known == .unreadable { doubt = .placeholderUnread }
            }
        }
        let state: String
        switch doubt {
        case .none: state = value.isEmpty ? "field empty" : "field has other text"
        case .mayBeThePlaceholder: state = "field reads its placeholder or the start of the text"
        case .placeholderUnread: state = "field has text, placeholder unreadable"
        }
        guard action["clear"]?.bool ?? false || value.isEmpty else {
            let reason: String
            switch doubt {
            case .none: reason = "the field holds \(shown(value)), which is not all of the text"
            case .mayBeThePlaceholder: reason = "the field reads \(shown(value)), which is either its placeholder or the start of the text"
            case .placeholderUnread: reason = "the field reads \(shown(value)); its placeholder could not be read, so it is not known whether that is text"
            }
            return (nil, "\(reason), so it was not typed again (a second try could double it)", "\(state), not typed again")
        }
        guard until - now() > 1.2 else {
            return (nil, value.isEmpty ? "the field is empty; there was no time left to type again" : "the field holds \(shown(value)); there was no time left to type again", "\(state), no time left to type again")
        }
        do {
            let (_, text) = try await withDeadline(until - now(), "the second try of the action") { [self] in try await perform(action, until: until) }
            return ("\(text) (sent again after the first try failed: \(why))", "", "")
        } catch {
            return (nil, "the text was typed again once and that failed too: \(error)", "\(state), typed again once and that failed too")
        }
    }

    /// The answer when the sensitive part was not sent: text only when nothing went, else the read
    /// after what did go.
    func refused(until: Double, full: Bool, did: [String], text: String) async -> ToolResult {
        guard !did.isEmpty else {
            // The screen it was refused on, so the model sees what it asked for (gym: the declined
            // answer was the one answer without a picture).
            let read = await readAndReply(until: until, full: full, changes: true)
            return ToolResult(text: text + " Nothing was sent.\n" + read.text, jpeg: read.jpeg, isError: true)
        }
        return await readAndReply(until: until, full: full, changes: true, did: did, error: text)
    }

    // MARK: Sensitivity

    /// Whether an input action would run with Poki in front: the app of the latest read, followed through
    /// the launches and Home presses before it.
    func landsInPoki(_ actions: [JSON]) -> Bool {
        var front = lastForeground
        for action in actions {
            if let spec = action["launch"] {
                front = Foreground(bundleID: spec.string ?? spec["bundle"]?.string, name: nil)
            } else if let button = action["button"]?.text {
                if button.lowercased() == "home" { front = nil }
            } else if action["wait"] != nil || action["wait_until"] != nil {
                continue
            } else if let spec = action["run"], let routine = memory?.routine(named: spec.string ?? spec["name"]?.string ?? ""),
                      let bundle = routine.steps.first?.action["launch"].flatMap({ $0.string ?? $0["bundle"]?.string }) ?? routine.app,
                      !config.isPoki(Foreground(bundleID: bundle, name: nil)) {
                // A run that begins with a launch (or whose app is launched first) leaves Poki on its
                // own: on the phone a task usually starts in Poki's own chat (gym finding 37).
                front = Foreground(bundleID: bundle, name: nil)
            } else if config.isPoki(front) {
                return true
            }
        }
        return false
    }

    func element(at point: (x: Double, y: Double), in elements: [Element]? = nil) -> Element? {
        (elements ?? lastElements).filter { f in f.frame.x <= point.x && point.x <= f.frame.x + f.frame.width && f.frame.y <= point.y && point.y <= f.frame.y + f.frame.height }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The element a spec points at: a number of the latest read, or what lies under a point (of the
    /// latest read, or of `elements`, where numbers mean nothing).
    func target(_ spec: JSON?, in elements: [Element]? = nil) -> Element? {
        guard let spec else { return nil }
        if let point = spec.array, point.count >= 2, let x = point[0].double, let y = point[1].double { return element(at: (x, y), in: elements) }
        if case .object = spec {
            if let ref = spec["ref"]?.int { return elements == nil ? refs[ref] : nil }
            if let x = spec["x"]?.double, let y = spec["y"]?.double { return element(at: (x, y), in: elements) }
            return nil
        }
        return elements == nil ? spec.int.flatMap { refs[$0] } : nil
    }

    func sensitiveReason(_ actions: [JSON]) -> String? { firstSensitive(actions)?.reason }

    /// What the approval check carries from one action to the next.
    struct SensitiveScan {
        /// The app the action lands in, followed through launches, Home and runs.
        var front: Foreground?
        /// The screen is still the one `elements` were read from: after a launch, Home or a run the
        /// numbers and points of that read belong to another screen.
        var read = true
        /// An action before this one may have changed the screen (a tap opens a conversation or a
        /// photo): a point is not judged by what the read had under it.
        var moved = false
        var typingTarget: Element?
        var secureOnScreen: Bool
        /// The elements to look under a point in; nil for the latest read (and its numbers).
        var elements: [Element]?
    }

    /// The first action that needs the owner's approval, and why.
    func firstSensitive(_ actions: [JSON]) -> (at: Int, reason: String)? {
        guard config.sensitive.enabled else { return nil }
        var scan = SensitiveScan(front: lastForeground, secureOnScreen: lastElements.contains(where: \.isSecure))
        for (at, action) in actions.enumerated() {
            if let reason = sensitive(action, &scan) { return (at, reason) }
        }
        return nil
    }

    /// Why this action needs the owner's approval, or nil; `scan` moves on past it. `do` checks its
    /// actions with it before sending any, and a routine run each step before it sends it.
    func sensitive(_ action: JSON, _ scan: inout SensitiveScan) -> String? {
        let rules = config.sensitive
        guard rules.enabled else { return nil }
        defer { if ["tap", "long_press", "type", "key", "swipe", "drag", "pinch", "scroll_to", "back"].contains(where: { action[$0] != nil }) { scan.moved = true } }
        let messaging = scan.front?.bundleID.map(rules.messagingApps.contains) ?? false
        // In a messaging app, after an action that may have opened another screen, that screen is not
        // read yet: the composer's Send sits where the list had nothing, and the search field's number
        // from the list no longer says where typed text goes.
        let unread = !scan.read || (scan.moved && messaging)
        if let spec = action["launch"] {
            scan.front = Foreground(bundleID: spec.string ?? spec["bundle"]?.string, name: nil)
            scan.read = false; scan.typingTarget = nil
        } else if action["button"]?.text?.lowercased() == "home" {
            scan.front = nil
            scan.read = false; scan.typingTarget = nil
        } else if let spec = action["run"] {
            // A routine sends its own taps and keys: in a guarded app, in front or the routine's own
            // (launched first), running it is input there.
            let name = spec.string ?? spec["name"]?.string ?? ""
            let app = memory?.routine(named: name)?.app
            for bundle in [scan.front?.bundleID, app].compactMap({ $0 }) where rules.guardedApps.contains(bundle) {
                return "input in \(bundle == scan.front?.bundleID ? scan.front?.describe ?? bundle : bundle) (routine \"\(name)\")"
            }
            if let app { scan.front = Foreground(bundleID: app, name: nil) }
            scan.read = false; scan.typingTarget = nil
        } else if let spec = action["tap"] ?? action["long_press"] {
            let e = unread ? nil : target(spec, in: scan.elements)
            if action["tap"] != nil { scan.typingTarget = e }
            if let r = rules.reason(touching: e, typing: false, app: scan.front, secureOnScreen: scan.secureOnScreen) { return r }
            let app = scan.front?.describe ?? "unknown"
            if unread, messaging { return "sending a message (a tap in \(app) on a screen not read yet)" }
            // After a launch or a run nothing of the app's screen was read: a Delete there reads as nothing.
            // The home screen after Home opens apps, which ask for themselves.
            if !scan.read, scan.front != nil { return "a tap on a screen not read yet (in \(app))" }
            if scan.moved, spec.array != nil || spec["x"] != nil {
                return "a tap at a point on a screen that may have changed since it was read (in \(app))"
            }
        } else if let text = action["type"]?.text {
            let e = if let ref = action["ref"] {
                unread ? nil : (scan.elements == nil ? refs[ref.int ?? -1] : nil) ?? scan.typingTarget
            } else {
                scan.read ? scan.typingTarget : nil
            }
            scan.typingTarget = e
            if let r = rules.reason(touching: e, typing: true, app: scan.front, secureOnScreen: scan.read && scan.secureOnScreen && e == nil) { return r }
            if messaging, text.contains(where: \.isNewline), !Self.isSearch(e) { return "sending a message (a return typed in \(scan.front?.describe ?? "unknown"))" }
        } else if action["key"]?.string?.lowercased() == "return", let field = scan.typingTarget, rules.reason(touching: field, typing: true, app: scan.front, secureOnScreen: false) != nil {
            return "submitting a password field"
        } else if messaging, let key = action["key"]?.text, (Self.keyText[key.lowercased()] ?? key).contains(where: \.isNewline), !Self.isSearch(scan.typingTarget) {
            // Return is the send key in WeChat, WhatsApp and Telegram: typed text goes out on it.
            return "sending a message (return in \(scan.front?.describe ?? "unknown"))"
        } else if action["key"] != nil || action["drag"] != nil, let bundle = scan.front?.bundleID, rules.guardedApps.contains(bundle) {
            // Waiting, handing the screen over, swipes, Home and launches are not input in a guarded app.
            return "input in \(scan.front?.describe ?? bundle)"
        }
        return nil
    }

    /// A search field: return there searches, it sends nothing.
    static func isSearch(_ field: Element?) -> Bool {
        guard let field else { return false }
        return field.type == "SearchField" || [field.text, field.identifier ?? ""].contains { $0.localizedCaseInsensitiveContains("search") || $0.contains("搜索") }
    }

    func describe(_ action: JSON) -> String {
        for key in ["tap", "long_press"] {
            if let spec = action[key] {
                if let e = target(spec), !e.text.isEmpty { return "\(key) \"\(e.text)\"" }
                return "\(key) \(spec.serialized())"
            }
        }
        if let text = action["type"]?.text {
            let e = action["ref"].flatMap { refs[$0.int ?? -1] }
            return e?.isSecure == true || lastElements.contains(where: \.isSecure) ? "type \(text.count) characters (hidden)" : "type \"\(text.prefix(40))\""
        }
        return action.serialized()
    }

    static func refs(in action: JSON) -> [Int] {
        var out: [Int] = []
        func add(_ value: JSON?) {
            guard let value else { return }
            switch value {
            case .number(let n): out.append(Int(n))
            case .string(let s): if let n = Int(s) { out.append(n) }
            case .object: if let r = value["ref"]?.int { out.append(r) }
            default: break
            }
        }
        for key in ["tap", "long_press", "pinch", "ref", "in"] { add(action[key]) }
        if case .object = action["drag"] { add(action["drag"]?["from"]); add(action["drag"]?["to"]) }
        if case .object = action["swipe"] { add(action["swipe"]?["in"]) }
        if case .object = action["scroll_to"] { add(action["scroll_to"]?["ref"]); add(action["scroll_to"]?["in"]) }
        return out
    }
}
