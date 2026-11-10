import Foundation
import CoreGraphics

/// Preferred extension path. A nil result means no execution grant was issued;
/// only that outcome permits native fallback. After a grant, uncertainty is fatal.
final class PokiKeyboardTyping {
    let call: NativeIME.Call
    let screen: CGSize
    init(screen: CGSize, call: @escaping NativeIME.Call) { self.screen = screen; self.call = call }

    func type(_ text: String, clear: Bool) async throws -> String? {
        guard !clear, !text.contains("\t"), KeyboardSession.directory != nil else { return nil }
        let parts = try NativeIME.plan(text)
        let initialTree = try await call(["op": "ax_tree", "direct": true])
        let initial = try NativeIME.field(initialTree)
        var expected = initial.value
        for character in text {
            if character == "\u{8}" { if !expected.isEmpty { expected.removeLast() } }
            else { expected.append(character) }
        }
        let id = UUID()
        let offer = KeyboardSession.State(id: id, expires: Date().addingTimeInterval(8), baseline: initial.value,
            pieces: parts.map { .init(text: $0.text, pinyin: $0.composition ? $0.keys : nil,
                                     language: $0.source == .pinyin ? "zh-Hans" : "en-US") })
        try KeyboardSession.access { state in
            if let state, state.expires > Date(), ["armed", "ready", "execute", "running", "done"].contains(state.phase) {
                throw KeyboardSession.failure("Another keyboard transaction is still active; native fallback was not started")
            }
            state = offer
        }
        var granted = false
        defer {
            // Revocation and execution claim are serialized across both processes.
            // Retain a short tombstone so a late keyboard appearance cannot replay.
            try? KeyboardSession.access { state in
                guard state?.id == id else { return }
                state?.phase = "cancelled"
                state?.expires = Date()
                state?.pieces = []
                state?.baseline = ""
            }
        }
        do {
            try Task.checkCancellation()
            if !(try ready(id)) {
                guard try await selectPanel(initialTree) else { return try await withdraw(id, initial: initial) }
            }
            let activationDeadline = Date().addingTimeInterval(3)
            while !(try ready(id)), Date() < activationDeadline {
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            guard try ready(id) else { return try await withdraw(id, initial: initial) }
            let current = try NativeIME.field(await call(["op": "ax_tree", "direct": true]))
            guard initial.sameTarget(as: current), current.value == initial.value else {
                throw KeyboardSession.failure("Focus changed before Poki keyboard typing")
            }
            try Task.checkCancellation()
            try KeyboardSession.access { state in
                guard state?.id == id, state?.phase == "ready", state!.expires > Date() else {
                    throw KeyboardSession.failure("Poki keyboard is no longer ready")
                }
                state?.phase = "execute"
                state?.expires = Date().addingTimeInterval(3)
            }
            granted = true
            let deadline = Date().addingTimeInterval(min(300, 30 + Double(text.count)))
            while Date() < deadline {
                try Task.checkCancellation()
                let state = try KeyboardSession.access { state -> KeyboardSession.State in
                    guard var current = state, current.id == id else {
                        throw KeyboardSession.failure("Keyboard receipt disappeared")
                    }
                    guard current.expires > Date() else { throw KeyboardSession.failure("Keyboard lease expired") }
                    if current.expires.timeIntervalSinceNow < 1.5 { current.expires = Date().addingTimeInterval(3) }
                    state = current
                    return current
                }
                if state.phase == "interrupted" {
                    throw NSError(domain: "PokiKeyboard", code: 2, userInfo: [NSLocalizedDescriptionKey: state.error ?? "User took over typing"])
                }
                if state.phase == "failed" { throw KeyboardSession.failure(state.error ?? "Keyboard input failed") }
                if state.phase == "done", state.exited {
                    // The extension receipt is not proof of the resulting field value.
                    for _ in 0..<3 {
                        let tree = try await call(["op": "ax_tree", "direct": true])
                        let field = try NativeIME.field(tree)
                        guard initial.sameTarget(as: field) else { throw KeyboardSession.failure("Typing focus changed") }
                        if field.value == expected { return field.value }
                        try await Task.sleep(nanoseconds: 40_000_000)
                    }
                    throw KeyboardSession.failure("Poki keyboard finished, but exact field contents were not confirmed")
                }
                guard ["execute", "running", "done"].contains(state.phase) else {
                    throw KeyboardSession.failure("Keyboard transaction stopped")
                }
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            throw KeyboardSession.failure("Poki keyboard timed out; text was not replayed")
        } catch {
            if (error as NSError).domain == "PokiKeyboard", (error as NSError).code == 2 { throw error }
            if granted { throw error }
            if error is CancellationError { throw error }
            // No execution grant means the extension was forbidden to insert text.
            // Focus must still be unchanged before handing over to native typing.
            let current = try NativeIME.field(await call(["op": "ax_tree", "direct": true]))
            guard initial.sameTarget(as: current), initial.value == current.value else { throw error }
            return try await withdraw(id, initial: initial)
        }
    }
    private func withdraw(_ id: UUID, initial: NativeIME.Field) async throws -> String? {
        let acknowledged = try KeyboardSession.access { state -> Bool in
            guard state?.id == id else { return false }
            if state?.phase == "interrupted" {
                throw NSError(domain: "PokiKeyboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "User took over typing"])
            }
            let active = state?.document != nil
            state?.phase = "cancelled"
            state?.pieces = []
            state?.baseline = ""
            return active
        }
        if acknowledged {
            let end = Date().addingTimeInterval(1)
            var exited = false
            repeat {
                exited = try KeyboardSession.access { $0?.id == id && $0?.exited == true }
                if exited { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            } while Date() < end
            guard exited else { throw KeyboardSession.failure("Poki keyboard did not acknowledge exit; fallback was not started") }
        }
        let current = try NativeIME.field(await call(["op": "ax_tree", "direct": true]))
        guard initial.sameTarget(as: current), initial.value == current.value else {
            throw NSError(domain: "PokiKeyboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Typing focus or text changed before fallback"])
        }
        return nil
    }
    private func ready(_ id: UUID) throws -> Bool {
        try KeyboardSession.access { state in
            if state?.id == id, state?.phase == "interrupted" {
                throw NSError(domain: "PokiKeyboard", code: 2, userInfo: [NSLocalizedDescriptionKey: state?.error ?? "User took over typing"])
            }
            return state?.id == id && state?.phase == "ready" && state!.expires > Date()
        }
    }
    private func tap(_ element: [String: Any], tree: [String: Any], hold: Bool = false) async throws {
        let point = try NativeIME.hidPoint(NativeIME.rect(element["frame"]), screen: screen,
                                           orientation: tree["orientation"] as? Int ?? 1)
        var request: [String: Any] = ["op": hold ? "long_press" : "tap", "x": point.0, "y": point.1]
        if hold { request["duration_ms"] = 450 }
        _ = try await call(request)
    }
    private func selectPanel(_ tree: [String: Any]) async throws -> Bool {
        // Select a named row, never cycle all sources or rewrite keyboard order.
        // Unknown/localized switchers safely use the existing native path.
        let elements = tree["elements"] as? [[String: Any]] ?? []
        let switches = elements.filter {
            ["Next keyboard", "Next Keyboard", "Switch keyboard", "下一个键盘", "下一键盘"].contains($0["label"] as? String ?? "")
            && ["Button", "Key"].contains($0["role"] as? String ?? "")
        }
        guard switches.count == 1 else { return false }
        try await tap(switches[0], tree: tree, hold: true)
        do {
            for _ in 0..<3 {
                let menu = try await call(["op": "ax_tree"])
                let rows = (menu["elements"] as? [[String: Any]] ?? []).filter {
                    $0["label"] as? String == "Poki" && ["Button", "Cell", "Key"].contains($0["role"] as? String ?? "")
                }
                if rows.count == 1 { try await tap(rows[0], tree: menu); return true }
                try await Task.sleep(nanoseconds: 60_000_000)
            }
        } catch {
            try await dismissPicker()
            throw error
        }
        try await dismissPicker()
        return false
    }
    private func dismissPicker() async throws {
        do { _ = try await call(["op": "ime", "key": "escape"]) }
        catch {
            _ = try await call(["op": "ime", "end": true])
            throw error
        }
        _ = try await call(["op": "ime", "end": true])
    }
}
