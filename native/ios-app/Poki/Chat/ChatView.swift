import AVFoundation
import SwiftUI

/// The chat page (ESP-171 boards "M Chat empty", "M Chat working", "M Chat approved"): Poki's picture and
/// name on top, the bubbles, and the message field. Approvals happen in the Dynamic Island, which iOS
/// hides while Poki is in front, so the chat also shows the waiting approval's card.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    var openDetails: () -> Void
    var openVoice: () -> Void
    var openSetup: () -> Void
    var openModel: () -> Void
    /// Back to the Sessions list, when the chat was opened from it.
    var back: (() -> Void)? = nil

    private var voice: VoiceModel { model.voice }
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        ChatTranscript(entries: chat.entries, typing: chat.awaitingModel, canRetry: chat.canRetry, retry: chat.retry) {
            if needsSetup { SetupBubble(paired: model.pairingPath != nil, openSetup: openSetup) }
            if !ApprovalClassifier.isOn, let approval = model.approvals.first {
                ApprovalCard(approval: approval) { approved in model.resolve(approval, approved: approved) }
            }
            LiveVoiceTranscript(voice: voice)
        }
        // The header and the message field are insets of the conversation, so the field sits right on
        // the keyboard (or the home indicator) and the bubbles scroll under both, as in Messages.
        .safeAreaInset(edge: .top, spacing: 0) {
            if voice.isOn { LiveVoiceBar(voice: voice).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .animation(.snappy, value: voice.isOn)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerInputView(running: chat.running, send: chat.send, stop: chat.stop, openVoice: openVoice, openModel: openModel,
                              newConversation: chat.newConversation)
        }
        .background(Color(.systemBackground))
        // The conversation's name (the one Poki gave it, or the owner's) is the title, and its title
        // menu renames it; the chat model is the subtitle on iOS 26.
        .navigationTitle(Text(verbatim: SessionStore.shared.session(chat.sessionID)?.name ?? "Poki"))
        .navigationBarTitleDisplayMode(.inline)
        .sessionSubtitle(ModelKeys.selectedModelName)
        .toolbarTitleMenu {
            if SessionStore.shared.session(chat.sessionID) != nil {
                Button("Rename", systemImage: "pencil") { newName = SessionStore.shared.session(chat.sessionID)?.name ?? ""; renaming = true }
            }
        }
        .alert("Rename Conversation", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { SessionStore.shared.rename(chat.sessionID, to: newName) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Conversation", systemImage: "square.and.pencil", action: chat.newConversation).disabled(chat.running)
                    Menu("Chat Model: \(ModelKeys.selectedModelName)", systemImage: "bubble.left.and.text.bubble.right") {
                        ForEach(ModelProvider.allCases.filter { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) { provider in
                            Section(provider.name) {
                                ForEach(ModelCatalog.available(provider)) { choice in
                                    Button {
                                        ModelKeys.selectedProvider = provider
                                        ModelKeys.selectedModel = choice.id
                                        ModelKeys.saved += 1
                                    } label: {
                                        if ModelKeys.selectedProvider == provider && ModelKeys.selectedModel == choice.id { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                                    }
                                }
                            }
                        }
                    }
                    if VoiceDirect.apiKey != nil {
                        Menu("Voice Model: \(VoiceDirect.model)", systemImage: "waveform") {
                            ForEach(ModelCatalog.voiceAvailable) { choice in
                                Button { ModelCatalog.voiceModel = choice.id } label: {
                                    if VoiceDirect.model == choice.id { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                                }
                            }
                        }
                    }
                    Button("Accounts", systemImage: "person.crop.circle", action: openModel)
                    Button("Status and Settings", systemImage: "gearshape", action: openDetails)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(Text("More"))
            }
        }
        // Full screen on iPhone; beside the sessions in a wide window, with the tabs kept.
    }

    /// Setup is not finished (nothing paired yet, or a step left after pairing, such as UI Automation):
    /// the chat says so, one tap from setup, as the old Home's Setup row did.
    private var needsSetup: Bool { (model.pairingPath == nil || model.setupStepsLeft) && !model.sessionOn && !chat.running && !chat.isSample }
}

/// The bubbles of one conversation: an in-app chat, a hand-off from an outside agent, or an outside
/// agent's own steps (grey lines). Used by the chat and by a saved session.
struct ChatTranscript<Footer: View>: View {
    var entries: [ChatEntry]
    var typing = false
    var canRetry = false
    var retry: () -> Void = {}
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    row(entry, at: i).id(entry.id)
                }
                if typing {
                    HStack { TypingBubble(); Spacer(minLength: .messageInsetPadding) }
                        .padding(.top, 4).transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
                }
                if canRetry {
                    Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Site.blue).padding(.top, 2).padding(.bottom, 6)
                }
                footer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .animation(PlanMotion.enter, value: entries)
            .animation(.easeOut(duration: 0.2), value: typing)
        }
        // Opens at the newest message, keeps a short chat at the bottom, and follows new lines (the
        // live voice transcript grows below the messages) while the content itself scrolls freely.
        // A frame fixed to the screen's height here cut off everything above it.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func row(_ entry: ChatEntry, at i: Int) -> some View {
        switch entry.kind {
        case .time(let date):
            Text(ChatTime.header(date))
                .font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
                .padding(.bottom, 6).frame(maxWidth: .infinity)
        case .you(let text, let delivered):
            let last = isLast(i, poki: false)
            VStack(alignment: .trailing, spacing: 4) {
                MessageBubble(direction: .outgoing, text: text, tail: last)
                if last, delivered {
                    Text("Delivered").font(.system(size: 11, weight: .medium)).foregroundStyle(ChatColor.secondary)
                        .padding(.horizontal, 4).padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .request(let text, let from):
            VStack(alignment: .trailing, spacing: 2) {
                if startsRun(i) || i == 0 {
                    Text(verbatim: from).font(.system(size: 11, weight: .medium)).foregroundStyle(ChatColor.secondary).padding(.horizontal, 14)
                }
                MessageBubble(direction: .outgoing, text: text, tail: isLast(i, poki: false))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .poki(let text):
            MessageBubble(direction: .incoming, text: text, tail: isLast(i, poki: true))
                .padding(.top, startsRun(i) ? 10 : 0)
                .transition(PlanMotion.stepTransition)
        case .plan(let steps):
            HStack {
                PlanBubble(steps: steps, tail: isLast(i, poki: true))
                Spacer(minLength: .messageInsetPadding)
            }
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(PlanMotion.stepTransition)
        case .note(let note):
            NoteLine(note: note)
        case .step(let text, let ok):
            StepLine(text: text, ok: ok)
        }
    }

    /// The last bubble from that side in the conversation has the small corner (the boards).
    private func isLast(_ i: Int, poki: Bool) -> Bool {
        !entries[(i + 1)...].contains { entry in
            switch entry.kind {
            case .poki, .plan: poki
            case .you, .request: !poki
            default: false
            }
        }
    }

    /// A bubble after the other side's (or the time) leaves 10 pt more.
    private func startsRun(_ i: Int) -> Bool {
        guard i > 0 else { return false }
        let mine = entries[i].isPoki
        for entry in entries[..<i].reversed() {
            switch entry.kind {
            case .note: continue
            case .time, .step: return true
            default: return entry.isPoki != mine
            }
        }
        return false
    }
}

extension ChatTranscript where Footer == EmptyView {
    init(entries: [ChatEntry]) { self.init(entries: entries, footer: { EmptyView() }) }
}

/// "Today 9:41 AM", "Yesterday 6:02 PM", "Monday 8:15 AM", "Oct 3, 8:15 AM", as Messages writes them.
enum ChatTime {
    static func header(_ date: Date) -> AttributedString {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(date) { day = String(localized: "Today") }
        else if calendar.isDateInYesterday(date) { day = String(localized: "Yesterday") }
        else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        }
        var bold = AttributedString(day)
        bold.font = .system(size: 12, weight: .semibold)
        return bold + AttributedString(" \(time)")
    }

    /// The Sessions list's right-hand time: "9:41 AM", "Yesterday", "Monday", "10/3/26".
    static func row(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// Three dots that rise in turn: the model is working on its answer.
struct TypingBubble: View {
    /// Dot i's height in 0...1 at time t. Typed step by step: as one expression inside the view
    /// builder it can exceed the type checker's time limit on a busy CI runner.
    static func phase(_ t: Double, _ i: Int) -> Double {
        let angle: Double = t * 2 * Double.pi / 1.2 - Double(i) * 0.9
        let wave: Double = sin(angle)
        return (wave + 1) / 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let phase = TypingBubble.phase(t, i)
                    Circle().fill(ChatColor.secondary.opacity(0.45 + 0.45 * phase)).frame(width: 8, height: 8).offset(y: -3 * phase)
                }
            }
            .padding(.vertical, 13).padding(.horizontal, 15)
            .background(ChatColor.incoming, in: UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: .tailRadius,
                                                                       bottomTrailingRadius: .cornerRadius, topTrailingRadius: .cornerRadius, style: .continuous))
        }
        .accessibilityLabel(Text("Poki is typing"))
    }
}

/// An outside agent's own step: one grey line, centred, ticked when it went through.
private struct StepLine: View {
    var text: String
    var ok: Bool?
    var body: some View {
        HStack(spacing: 5) {
            switch ok {
            case true?: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(ChatColor.green)
            case false?: Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(.systemRed))
            case nil: ProgressView().controlSize(.mini)
            }
            Text(text).lineLimit(2)
        }
        .font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
        .multilineTextAlignment(.center)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

// MARK: Header


/// The bear in a round frame, as the ESP-171 boards draw it (`PokiFace.png` is the boards' own image: the
/// app icon's bear, closer up).
struct PokiAvatar: View {
    var size: CGFloat
    static let face = UIImage(named: "PokiFace")
    var body: some View {
        Group {
            if let face = Self.face { Image(uiImage: face).resizable().scaledToFill() } else { Image("Bear").resizable().scaledToFill() }
        }
        .frame(width: size, height: size).clipShape(.circle)
        .accessibilityHidden(true)
    }
}

// MARK: Plan

/// The steps of a task in one Poki bubble: done steps ticked, the step under way typing its words.
struct PlanBubble: View {
    var steps: [PlanStep]
    var tail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(steps) { step in
                PlanRow(step: step).transition(PlanMotion.stepTransition)
            }
        }
        .animation(PlanMotion.enter, value: steps)
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(width: 250, alignment: .leading)
        .background(ChatColor.incoming, in: UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: tail ? .tailRadius : .cornerRadius,
                                                                    bottomTrailingRadius: .cornerRadius, topTrailingRadius: .cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct PlanRow: View {
    var step: PlanStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ZStack {
                switch step.state {
                case .done:
                    DrawingCheck(color: ChatColor.green).frame(width: 12, height: 12).transition(PlanMotion.swapTransition)
                case .failed:
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(.systemRed)).transition(PlanMotion.swapTransition)
                case .current, .waiting:
                    Circle().strokeBorder(ChatColor.secondary.opacity(0.6), lineWidth: 1).frame(width: 13, height: 13).transition(PlanMotion.swapTransition)
                }
            }
            .frame(width: 13)
            .animation(PlanMotion.swap, value: step.state)
            Group {
                switch step.state {
                case .current, .waiting:
                    TypewriterText(text: step.state == .waiting ? String(localized: "\(step.text), waiting for you") : step.text,
                                   font: .system(size: 15), color: ChatColor.pending)
                case .done, .failed:
                    Text(step.text).font(.system(size: 15)).foregroundStyle(Color(.label))
                        .transition(PlanMotion.swapTransition.animation(PlanMotion.swap.delay(PlanMotion.stagger)))
                }
            }
            .animation(PlanMotion.complete, value: step.state)
        }
        .lineLimit(2)
    }
}

// MARK: Notes

/// One grey line about an approval, centred under the steps.
private struct NoteLine: View {
    var note: ChatNote
    var body: some View {
        HStack(spacing: 6) {
            switch note {
            case .waiting:
                // The Dynamic Island, small.
                Capsule().fill(Color(hex: 0x1C1C1E)).frame(width: 22, height: 8)
                Text("Waiting for your approval")
            case .approved(let at):
                Text(verbatim: "✓").fontWeight(.semibold).foregroundStyle(ChatColor.green)
                Text("Approved, \(at.formatted(date: .omitted, time: .shortened))")
            case .declined:
                Text(verbatim: "✕").fontWeight(.semibold).foregroundStyle(Color(.systemRed))
                Text("Not approved, so Poki skipped that step")
            case .expired:
                Text("The approval ran out, so Poki skipped that step")
            case .problem(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.systemOrange))
                Text(text)
            case .modelChecking:
                ProgressView().controlSize(.mini)
                Text("The model is checking this step")
            case .modelApproved(let why):
                Text(verbatim: "✓").fontWeight(.semibold).foregroundStyle(ChatColor.green)
                Text(why.isEmpty ? String(localized: "Approved by model") : String(localized: "Approved by model: \(why)"))
            case .modelDeclined(let why):
                Text(verbatim: "✕").fontWeight(.semibold).foregroundStyle(Color(.systemRed))
                Text(why.isEmpty ? String(localized: "Not approved by model. Say yes in the chat to let it through.") : String(localized: "Not approved by model: \(why). Say yes in the chat to let it through."))
            }
        }
        .font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, note == .waiting ? 12 : 10).padding(.bottom, note == .waiting ? 2 : 10)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }
}

/// Before setup, or with a step left: Poki says so, and the bubble opens setup.
private struct SetupBubble: View {
    var paired: Bool
    var openSetup: () -> Void
    var body: some View {
        HStack {
            Button(action: openSetup) {
                HStack(spacing: 4) {
                    Text(paired ? "Finish setting up this iPhone." : "First, set up this iPhone. About 5 minutes.")
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                }
                .font(.system(size: 17)).foregroundStyle(Site.blue)
                .padding(.vertical, .messageVerticalPadding).padding(.horizontal, 14)
                .background(ChatColor.incoming, in: UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: .tailRadius,
                                                                            bottomTrailingRadius: .cornerRadius, topTrailingRadius: .cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            Spacer(minLength: .messageInsetPadding)
        }
        .padding(.top, 4)
    }
}

// MARK: Composer

// ComposerInputView started from GetStream/swiftui-iMessage-clone (commit df114b4,
// iMessageClone/MessageList/View/Composer/ComposerInputView.swift, by Stefan Blos; no licence file in
// the repository), with the plus button in front from exyte/Chat (commit f382a14,
// Sources/ExyteChat/Views/InputView/InputView.swift, Copyright (c) 2019 exyte, MIT License). Now: a
// Liquid Glass field on iOS 26 (a bar material before it), dictation that writes into the field as you
// speak, the live voice button, and a stop button while a task runs.
struct ComposerInputView: View {
    @Environment(AppModel.self) private var model
    var running: Bool
    var send: (String) -> Void
    var stop: () -> Void
    /// Starts the live voice conversation.
    var openVoice: () -> Void
    var openModel: () -> Void
    var newConversation: () -> Void
    @State private var input = ""
    @State private var dictation = FieldDictation()
    @FocusState private var focused: Bool
    @State private var liveNote: String?

    private var voice: VoiceModel { model.voice }
    private var hasText: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 4) {
            if dictation.on {
                HStack(spacing: 6) {
                    Circle().fill(Color(.systemRed)).frame(width: 7, height: 7)
                    Text("Dictating. Your words go into the message; tap Send when it reads right.")
                }
                .font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                .transition(.opacity)
            } else if let liveNote {
                Text(liveNote).font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    .onTapGesture { self.liveNote = nil; openModel() }
            } else if let problem = dictation.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Color(.systemRed))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(text: $input, prompt: Text(dictation.on ? "Listening…" : "Message Poki").foregroundStyle(ChatColor.placeholder), axis: .vertical) { Text("Message Poki") }
                        .accessibilityIdentifier("poki.chat.input")
                        .font(.system(size: 17))
                        .focused($focused)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1...6)
                        .padding(.vertical, 9)
                        .submitLabel(.send)
                        .onSubmit(submit)
                    trailing.frame(height: 40)
                }
                .padding(.leading, 16).padding(.trailing, 4)
                .frame(minHeight: 40)
                .composerGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        }
        .animation(.snappy, value: dictation.on)
        .onChange(of: dictation.text) { _, text in if dictation.on { input = dictation.base + text } }
        .onDisappear { dictation.stop(model) }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 2) {
            if running {
                Button(action: stop) {
                    Image(systemName: "stop.circle.fill").resizable().scaledToFit().frame(width: 30, height: 30).foregroundStyle(.white, Site.blue)
                }
                .accessibilityLabel(Text("Stop"))
            } else {
                // Dictation: the words appear in the field; nothing is sent until you tap Send.
                Button { dictation.on ? dictation.stop(model) : dictation.start(model, after: input) } label: {
                    Image(systemName: dictation.on ? "mic.fill" : "mic")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(dictation.on ? Color(.systemRed) : ChatColor.secondary)
                        .symbolEffect(.pulse, isActive: dictation.on)
                        .frame(width: 34, height: 40).contentShape(.rect)
                }
                .disabled(voice.isOn)
                .accessibilityLabel(Text(dictation.on ? "Stop Dictation" : "Dictate"))
                if hasText {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").resizable().scaledToFit().frame(width: 30, height: 30).foregroundStyle(.white, Site.blue)
                    }
                    .accessibilityLabel(Text("Send"))
                    .accessibilityIdentifier("poki.chat.send")
                } else {
                    // The live voice conversation: Poki listens and answers out loud. It ends 8 s after an answer if nobody speaks, in the background, or when you end it.
                    Button {
                        if voice.isOn { voice.stop() }
                        else if !voice.canTalkLive {
                            liveNote = String(localized: "Live voice needs an OpenAI API key (tap here for Model) or the voice bridge. The microphone in the field dictates with any model.")
                        } else { liveNote = nil; dictation.stop(model); openVoice() }
                    } label: {
                        Image(systemName: voice.isOn ? "waveform.circle.fill" : "waveform.circle")
                            .resizable().scaledToFit().frame(width: 30, height: 30)
                            .foregroundStyle(voice.isOn ? AnyShapeStyle(Site.blue) : AnyShapeStyle(ChatColor.secondary))
                            .symbolEffect(.variableColor.iterative, isActive: voice.isOn)
                    }
                    // A tap is felt at once, before the connection is up.
                    .sensoryFeedback(.impact(weight: .medium), trigger: voice.isOn)
                    .accessibilityLabel(Text(voice.isOn ? "End Live Voice" : "Live Voice"))
                }
            }
        }
    }

    private func submit() {
        guard !running, hasText else { return }
        dictation.stop(model)
        send(input)
        input = ""
    }
}

/// Dictation into the message field (Apple's speech recognition, on the device when it can), separate
/// from the live conversation: it only writes words, it never sends them.
@MainActor
@Observable
final class FieldDictation {
    private(set) var on = false
    private(set) var text = ""
    private(set) var base = ""
    private(set) var problem: String?
    private var engine: Dictation?

    func start(_ model: AppModel, after current: String) {
        guard !on else { return }
        problem = nil
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        base = trimmed.isEmpty ? "" : trimmed + " "
        text = ""
        Task {
            guard await Dictation.allowed() else {
                problem = String(localized: "Poki needs the microphone and speech recognition: allow them in Settings › Poki.")
                return
            }
            let engine = Dictation()
            engine.onHeard = { [weak self] heard in self?.text = heard }
            model.background.pauseAudio()
            do {
                try engine.listen()
                self.engine = engine
                on = true
            } catch {
                model.background.resumeAudio()
                problem = error.localizedDescription
            }
        }
    }

    func stop(_ model: AppModel) {
        guard on, let engine else { return }
        on = false
        self.engine = nil
        Task {
            _ = await engine.finish()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            model.background.resumeAudio()
        }
    }
}

// MARK: Live voice

/// Under the header while a live conversation is on: whether Poki is listening, hearing you, working or
/// speaking, and the buttons to quiet it or end it.
struct LiveVoiceBar: View {
    var voice: VoiceModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: voice.phase == .hearing || voice.phase == .speaking)
                .frame(width: 30, height: 30).background(tint, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.isLive ? "Live Voice" : "Voice, turn by turn").font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(ChatColor.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if voice.phase == .speaking {
                Button { voice.stopTalking() } label: { Image(systemName: "speaker.slash.fill") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel(Text("Stop Talking"))
            }
            Button("End", role: .destructive) { voice.stop() }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color(.systemRed)).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .composerGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }

    private var symbol: String {
        switch voice.phase {
        case .hearing: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .lost: "exclamationmark"
        default: "mic.fill"
        }
    }

    private var tint: Color {
        switch voice.phase {
        case .hearing: Color(.systemRed)
        case .lost: Color(.systemOrange)
        default: Site.blue
        }
    }

    private var detail: String {
        switch voice.phase {
        case .connecting: String(localized: "Connecting…")
        case .listening: voice.isLive ? String(localized: "Listening. Just talk; Poki answers when you pause.") : String(localized: "Ready")
        case .hearing: String(localized: "Hearing you…")
        case .thinking: String(localized: "Working on it…")
        case .speaking: String(localized: "Speaking")
        case .off: String(localized: "Off")
        case .lost(let why): why
        }
    }
}

/// What was said in the live conversation, as bubbles under the chat: your words (grey while Poki is
/// still hearing them), Poki's answers, and its steps as grey lines.
struct LiveVoiceTranscript: View {
    var voice: VoiceModel

    var body: some View {
        if voice.isOn || !voice.lines.isEmpty {
            let lines = voice.lines
            VStack(spacing: 4) {
                if !lines.isEmpty {
                    Label("Voice conversation", systemImage: "waveform")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ChatColor.secondary)
                        .padding(.top, 12).padding(.bottom, 4).frame(maxWidth: .infinity)
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    let pending = i == lines.count - 1 && line.role == .you && voice.phase == .hearing
                    switch line.role {
                    case .you:
                        MessageBubble(direction: .outgoing, text: line.text, tail: true).opacity(pending ? 0.55 : 1)
                    case .poki:
                        MessageBubble(direction: .incoming, text: line.text, tail: true)
                    case .tool, .note:
                        Text(line.text).font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
                            .multilineTextAlignment(.center).lineLimit(2).padding(.vertical, 3).frame(maxWidth: .infinity)
                    }
                }
                if voice.phase == .hearing, lines.last?.role != .you {
                    MessageBubble(direction: .outgoing, text: String(localized: "Listening…"), tail: true).opacity(0.55)
                }
            }
            .animation(PlanMotion.enter, value: voice.lines)
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later; the bar material with a hairline edge before it.
    @ViewBuilder func composerGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.bar, in: shape).overlay(shape.stroke(ChatColor.fieldEdge, lineWidth: 0.5))
        }
    }
}
