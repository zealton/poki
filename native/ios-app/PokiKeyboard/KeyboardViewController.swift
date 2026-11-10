import UIKit

/// Automation surface only. It never accepts manual keystrokes or uses a pasteboard.
final class KeyboardViewController: UIInputViewController {
    private var worker: Task<Void, Never>?
    private var sessionID: UUID?
    private var marked = false
    private var leaving = false
    private let switchKey = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        let label = UILabel()
        label.text = "Poki is typing"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.addSubview(label)
        // This is the system source switcher, not a manual typing key. In
        // particular, iPad may have no external globe when this key is required.
        switchKey.setImage(UIImage(systemName: "globe"), for: .normal)
        switchKey.accessibilityLabel = "Next keyboard"
        switchKey.translatesAutoresizingMaskIntoConstraints = false
        switchKey.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        view.addSubview(switchKey)
        NSLayoutConstraint.activate([
            switchKey.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            switchKey.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            switchKey.widthAnchor.constraint(equalToConstant: 44),
            switchKey.heightAnchor.constraint(equalToConstant: 44)
        ])
        let height = view.heightAnchor.constraint(equalToConstant: traitCollection.userInterfaceIdiom == .pad ? 350 : 260)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([height, label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        switchKey.isHidden = !needsInputModeSwitchKey
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard worker == nil else { return }
        leaving = false
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run()
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        if !leaving, let id = sessionID {
            // Disappearance during an armed/active transaction is a takeover,
            // even when iOS cannot tell us whether it was a globe switch or focus loss.
            try? KeyboardSession.access { state in
                guard state?.id == id, ["ready", "execute", "running"].contains(state?.phase ?? "") else { return }
                state?.phase = "interrupted"
                state?.error = "You changed keyboards or left the typing field. Poki is paused while you edit."
                state?.pieces = []
                state?.baseline = ""
            }
            leaving = true // Never advance again after the user chose a keyboard.
        }
        leaving = true
        worker?.cancel()
        super.viewWillDisappear(animated)
    }
    private func leave() {
        guard !leaving else { return }
        leaving = true
        advanceToNextInputMode()
    }
    private func check(_ id: UUID, document: UUID) throws {
        try Task.checkCancellation()
        guard hasFullAccess, textDocumentProxy.documentIdentifier == document else {
            throw NSError(domain: "PokiKeyboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "Typing document changed"])
        }
        try KeyboardSession.access { state in
            guard let state, state.id == id, state.phase == "running", state.expires > Date() else {
                throw KeyboardSession.failure("Typing session expired or was cancelled")
            }
        }
    }
    private func pause(_ milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
    private func run() async {
        defer {
            leave()
            if let id = sessionID {
                try? KeyboardSession.access { state in
                    if state?.id == id { state?.exited = true }
                }
            }
            worker = nil
            sessionID = nil
        }
        guard hasFullAccess else { return }
        do {
            let document = textDocumentProxy.documentIdentifier
            // Only append/end-of-field edits are eligible. Native typing handles
            // selection replacement, clear, and contexts hidden by the host app.
            guard let before = textDocumentProxy.documentContextBeforeInput,
                  textDocumentProxy.documentContextAfterInput == "",
                  (textDocumentProxy.selectedText ?? "").isEmpty else { return }
            let offer: KeyboardSession.State? = try KeyboardSession.access { state in
                guard var current = state, current.phase == "armed", current.expires > Date(),
                      current.baseline.hasSuffix(before), !before.isEmpty || current.baseline.isEmpty
                else { return nil }
                current.document = document
                current.phase = "ready"
                state = current
                return current
            }
            guard let offer else { return }
            sessionID = offer.id
            while true {
                try Task.checkCancellation()
                let start = try KeyboardSession.access { state -> Bool in
                    guard var current = state, current.id == offer.id, current.expires > Date(),
                          ["ready", "execute"].contains(current.phase) else {
                        throw KeyboardSession.failure("Typing offer withdrawn")
                    }
                    if current.phase == "execute" {
                        current.phase = "running"; state = current; return true
                    }
                    return false
                }
                if start { break }
                try await pause(20)
            }
            var expectedContext = offer.baseline
            for (index, piece) in offer.pieces.enumerated() {
                try check(offer.id, document: document)
                guard let context = textDocumentProxy.documentContextBeforeInput,
                      expectedContext.hasSuffix(context), !context.isEmpty || expectedContext.isEmpty,
                      textDocumentProxy.documentContextAfterInput == "",
                      (textDocumentProxy.selectedText ?? "").isEmpty else {
                    throw NSError(domain: "PokiKeyboard", code: 2, userInfo: [NSLocalizedDescriptionKey: "The user changed the text or insertion point"])
                }
                primaryLanguage = piece.language
                if let pinyin = piece.pinyin {
                    var composition = ""
                    for key in pinyin {
                        try check(offer.id, document: document)
                        composition.append(key)
                        marked = true
                        textDocumentProxy.setMarkedText(composition, selectedRange: NSRange(location: composition.utf16.count, length: 0))
                        try await pause(UInt64.random(in: 8...18))
                    }
                    // A rare, bounded typo is confined to marked text. It never
                    // modifies previously committed words or the user's content.
                    if index % 17 == 8 {
                        try check(offer.id, document: document)
                        textDocumentProxy.setMarkedText(composition + "g", selectedRange: NSRange(location: composition.utf16.count + 1, length: 0))
                        try await pause(45)
                        try check(offer.id, document: document)
                        textDocumentProxy.setMarkedText(composition, selectedRange: NSRange(location: composition.utf16.count, length: 0))
                    }
                    try check(offer.id, document: document)
                    textDocumentProxy.setMarkedText(piece.text, selectedRange: NSRange(location: piece.text.utf16.count, length: 0))
                    textDocumentProxy.unmarkText()
                    marked = false
                } else {
                    for (offset, character) in piece.text.enumerated() {
                        try check(offer.id, document: document)
                        if character == "\u{8}" { textDocumentProxy.deleteBackward() }
                        else if piece.language == "en-US", character.isLetter, offset % 97 == 41 {
                            marked = true
                            textDocumentProxy.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0))
                            try await pause(45)
                            try check(offer.id, document: document)
                            textDocumentProxy.setMarkedText(String(character), selectedRange: NSRange(location: String(character).utf16.count, length: 0))
                            textDocumentProxy.unmarkText()
                            marked = false
                        } else { textDocumentProxy.insertText(String(character)) }
                        try await pause(UInt64.random(in: 8...18))
                    }
                }
                for character in piece.text {
                    if character == "\u{8}" { if !expectedContext.isEmpty { expectedContext.removeLast() } }
                    else { expectedContext.append(character) }
                }
                try await pause(UInt64.random(in: 15...35))
            }
            try check(offer.id, document: document)
            try KeyboardSession.access { state in
                guard state?.id == offer.id, state?.phase == "running" else {
                    throw KeyboardSession.failure("Typing session withdrawn")
                }
                state?.phase = "done"
                state?.pieces = []
                state?.baseline = ""
            }
        } catch {
            // Never clear marked text in a different document after focus changes.
            if marked, !leaving, let id = sessionID,
               let document = try? KeyboardSession.access({ $0?.id == id ? $0?.document : nil }),
               document == textDocumentProxy.documentIdentifier {
                textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
                textDocumentProxy.unmarkText()
            }
            marked = false
            try? KeyboardSession.access { state in
                guard state?.id == sessionID, state?.phase != "interrupted" else { return }
                state?.phase = (error as NSError).domain == "PokiKeyboard" && (error as NSError).code == 2 ? "interrupted" : "failed"
                state?.error = error.localizedDescription
                state?.pieces = []
                state?.baseline = ""
            }
        }
    }
}
