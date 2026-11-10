import CoreImage.CIFilterBuiltins
import PokiCore
import SwiftUI

/// Settings, the sheet behind Home's gear (ESP-139 board 04): this iPhone and its relay, the agents
/// (one MCP address each, revocable), the runner, and setup and diagnostics. White cards on the blue.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var path: [SettingsRoute]
    var openSetup: () -> Void

    init(start: [SettingsRoute] = [], openSetup: @escaping () -> Void) {
        _path = State(initialValue: start)
        self.openSetup = openSetup
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsHome(push: { path.append($0) }, openSetup: openSetup, done: { dismiss() })
                .navigationDestination(for: SettingsRoute.self) { route in
                    SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
                }
        }
        .presentationDragIndicator(.visible)
    }
}

enum SettingsRoute: Hashable {
    case connector(ConnectorSecret), relay, diagnostics, log, activityPreview, memory
}

/// The page for a settings route, in whichever navigation stack pushed it.
struct SettingsDestination: View {
    var route: SettingsRoute
    var push: (SettingsRoute) -> Void
    var pop: () -> Void
    var body: some View {
        switch route {
        case .connector(let secret): ConnectorDetail(secret: secret, back: pop)
        case .relay: RelayView(back: pop)
        // Diagnostics pushes its own pages (Log, Live Activity Preview) and pops itself.
        case .diagnostics: DiagnosticsView(path: Binding(get: { [.diagnostics] }, set: { new in
            if new.count > 1, let last = new.last { push(last) } else if new.isEmpty { pop() }
        }))
        case .log: LogView(back: pop)
        case .memory: MemoryView(back: pop)
        case .activityPreview: ActivityPreview()
        }
    }
}

/// Agents and Relay: this iPhone, the agents' MCP addresses, the runner and this iPhone's setup.
struct SettingsHome: View {
    @State private var showLearning = false
    @AppStorage("poki.experimental.userRoutines") private var userRoutines = false
    @Environment(AppModel.self) private var model
    var push: (SettingsRoute) -> Void
    var openSetup: () -> Void
    var done: (() -> Void)? = nil

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 12) {
                    BearAvatar(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This iPhone").font(.headline)
                        Text(verbatim: model.identity.label.isEmpty ? "—" : "\(model.identity.label.prefix(12))…")
                            .font(.footnote.monospaced()).foregroundStyle(Color(.secondaryLabel))
                    }
                    Spacer()
                    let relay = Health.relay(model)
                    Label(relay.word, systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon).font(.subheadline)
                        .foregroundStyle(relay.color == Site.ok ? Color.green : relay.color == Site.bad ? Color.red : Color.secondary)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("The relay forwards requests to this iPhone while Poki is open or in the background. It stores nothing; when offline, clients receive an error.")
            }

            Section {
                ForEach(model.identity.secrets) { secret in
                    NavigationLink(value: SettingsRoute.connector(secret)) {
                        LabeledContent(secret.name, value: secret.created.formatted(.dateTime.month(.abbreviated).day()))
                    }
                    .disabled(model.relayAddress == nil)
                    .swipeActions { Button("Revoke", role: .destructive) { model.revoke(secret) } }
                    .contextMenu { Button("Revoke Access", systemImage: "xmark.circle", role: .destructive) { model.revoke(secret) } }
                }
                Button(action: add) {
                    Label { Text("Add Agent") } icon: { Image(systemName: "plus.circle.fill").foregroundStyle(.blue) }
                }
                .disabled(model.relayAddress == nil)
                if let error = model.identity.error {
                    Label(Self.friendly(error), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            } header: {
                Text("Agents")
            } footer: {
                if model.relayAddress == nil { Text("Set your relay address first: each agent’s address is on your relay.") }
            }

            Section {
                Text("Poki keyboard").font(.headline)
                    .onLongPressGesture(minimumDuration: 3) { showLearning.toggle() }
                if showLearning {
                    Toggle("Create routines from user demonstrations", isOn: $userRoutines)
                    Text("Experimental. Observed corrections become user-assisted checkpoints, never guessed taps or unattended replay. Off by default.").font(.footnote)
                }
                Text("For faster agent typing, enable Poki in Settings → General → Keyboard → Keyboards → Add New Keyboard, then allow Full Access. Keep your usual keyboards enabled.")
                Text("The panel only says ‘Poki is typing’. It leaves automatically when finished. Switching keyboards while it types pauses Poki until you tap Done. Native typing remains the fallback.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Full Access is used for local communication with Poki. This keyboard does not use the clipboard or send your typing over the network.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if model.automationPath == .inProcess {
                Section {
                    Toggle("Hide Banner When Idle", isOn: $model.closeSessionWhenIdle)
                } header: {
                    Text("Automation")
                } footer: {
                    Text("Ends the automation session, and iOS’s banner with it, when the agent stops. Being tested: if the agent can’t see the screen after this, turn it off and open Poki again.")
                }
            }
            // The in-process path has no Poki Runner to start or stop (ESP-152).
            if model.automationPath == .runner {
                Section {
                    LabeledContent("Runner", value: Health.runner(model).word)
                    Picker("Stop When Idle For", selection: $model.idleStopSeconds) {
                        ForEach(Self.idleChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if model.runnerPaused {
                        Button("Start Now") { model.wakeRunner() }
                    } else {
                        Button("Stop Runner", role: .destructive) { model.pauseRunner() }.disabled(!model.approvals.isEmpty)
                    }
                } header: {
                    Text("Runner")
                } footer: {
                    Text("iOS shows the automation banner only while the runner is active. Poki starts it when needed and stops it when idle. Don’t close Poki Runner while an agent is working.")
                }
            }

            Section {
                let done = SetupStep.shown.filter(model.isDone).count
                let total = SetupStep.shown.count
                NavigationLink(value: SettingsRoute.relay) {
                    LabeledContent("Relay") {
                        Text(model.relayAddress.map { $0.origin.host() ?? $0.origin.absoluteString } ?? String(localized: "Not Set"))
                            .foregroundStyle(model.relayAddress == nil ? Color.red : Color.secondary)
                    }
                }
                Button(action: openSetup) {
                    LabeledContent("Setup") {
                        Text("\(done) of \(total)").foregroundStyle(done == total ? Color.green : Color.secondary)
                    }
                }
                .foregroundStyle(Color(.label))
            } header: {
                Text("This iPhone")
            } footer: {
                Text(model.automationPath == .inProcess
                     ? "iOS shows the automation banner only while Poki’s automation session is open. Poki opens it when an agent asks and closes it when idle. Memory holds the routines and notes every agent shares."
                     : model.automationPath == .nativeServices
                     ? "Experimental native services controls the phone without an XCTest automation session or its banner. Change it in Diagnostics."
                     : "Memory holds the routines and notes every agent shares. Diagnostics: logs, checks, background hold, addresses, and Live Activity preview.")
            }
        }
        .navigationTitle("Agents and Relay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let done { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        }
    }

    private func add() {
        guard model.relayAddress != nil else { return }
        push(.connector(model.addConnector(name: "")))
    }

    static let idleChoices: [(Int, LocalizedStringKey)] = [
        (30, "30 seconds"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (0, "Never"),
    ]

    /// Keychain errors in words. -34018 means the app's signature has no keychain access (an unsigned
    /// or wrongly signed build); everything else shows its code.
    static func friendly(_ error: String) -> String {
        if error.contains("-34018") {
            return String(localized: "Poki cannot access the keychain and has no relay key yet. Reinstall Poki with your signing tool, then reopen Settings.")
        }
        return String(localized: "Poki couldn’t read its relay key from the keychain (\(error)).")
    }
}

/// The person's own relay. There is no default: until it is set, Poki sends nothing anywhere. The
/// board does not draw this page; it is Settings' white card and footnote style.
struct RelayView: View {
    @Environment(AppModel.self) private var model
    var back: () -> Void
    @State private var text = ""
    @State private var rejected = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("https://poki-relay.you.workers.dev", text: $text)
                    .font(.body.monospaced())
                    .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done).onSubmit(save)
            } header: {
                Text("Relay Address")
            } footer: {
                if rejected {
                    Text("That is not a relay address. Enter the address deploy.sh printed, such as https://poki-relay.you.workers.dev.").foregroundStyle(.red)
                } else {
                    Text("Poki has no default relay. Deploy your own to your Cloudflare account with deploy/cf-relay/deploy.sh from the Poki repository, then enter the address it prints. Screenshots and taps pass only through that relay.")
                }
            }
            Section("Status") { LabeledContent("Relay", value: statusText) }
        }
        .navigationTitle("Relay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) } }
        .onAppear { text = model.relayAddress?.origin.absoluteString ?? ""; if model.relayAddress == nil { focused = true } }
    }

    private var canSave: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != model.relayAddress?.origin.absoluteString
    }

    /// "Online", or "Offline: why" with PokiCore's reason as it came.
    private var statusText: String {
        if case .offline(let why) = model.relayStatus { return "\(Health.relay(model).word): \(why)" }
        return Health.relay(model).word
    }

    private func save() {
        rejected = !model.setRelay(text)
        if !rejected { focused = false }
    }
}

/// One agent's MCP address: a QR code, the address with its secret hidden, Copy, and Revoke.
struct ConnectorDetail: View {
    @Environment(AppModel.self) private var model
    /// As the page was opened; its name and agent are read live (`secret`), since both can change.
    var opened: ConnectorSecret
    var back: () -> Void
    @State private var copied = false
    @State private var renaming = false
    @State private var newName = ""

    init(secret: ConnectorSecret, back: @escaping () -> Void) { opened = secret; self.back = back }

    private var secret: ConnectorSecret { model.identity.secrets.first { $0.secret == opened.secret } ?? opened }

    var body: some View {
        // Rows and Add open this only once a relay is set, so the address is there.
        let url = model.connectorURL(for: secret)?.absoluteString ?? ""
        Form {
            if url.isEmpty {
                Section {
                    Text("Set your relay in Agents to get this connector’s address.").foregroundStyle(Color(.secondaryLabel))
                }
            } else {
            Section {
                if let qr = QRCode.image(url) {
                    Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 180, height: 180).padding(16)
                        .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("QR code of the address"))
                }
                Text(verbatim: url.replacingOccurrences(of: secret.secret, with: "••••••"))
                    .font(.footnote.monospaced()).foregroundStyle(Color(.secondaryLabel)).textSelection(.disabled)
                Button(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = url
                    copied = true
                }
            } footer: {
                Text("Add this URL as a remote MCP server in your client. Anyone with this link can control this iPhone while Poki is running. Keep it private, and revoke it here if compromised.")
            }
            }
            Section {
                let recent = Array(SessionStore.shared.sessions(for: secret, among: model.identity.secrets).prefix(20))
                if recent.isEmpty {
                    Text("No agent has used this connector yet.").foregroundStyle(Color(.secondaryLabel))
                }
                ForEach(recent) { session in
                    HStack(spacing: 12) {
                        AgentBadge(name: session.client ?? "", size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: session.name).font(.body.weight(.semibold)).lineLimit(1)
                            let line = session.lastLine
                            if !line.isEmpty { Text(verbatim: line).font(.subheadline).foregroundStyle(Color(.secondaryLabel)).lineLimit(2) }
                        }
                        Spacer(minLength: 8)
                        Text(session.live ? String(localized: "now") : ChatTime.row(session.updated))
                            .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Recent Use")
            }
            Section {
                LabeledContent("Added", value: secret.created.formatted(date: .abbreviated, time: .omitted))
                Button("Revoke Access", role: .destructive) { model.revoke(secret); back() }
            }
        }
        .navigationTitle(Text(verbatim: secret.name))
        .navigationBarTitleDisplayMode(.inline)
        // The name is the title; its menu renames it, as a session's does.
        .toolbarTitleMenu {
            Button("Rename", systemImage: "pencil") { newName = secret.name; renaming = true }
        }
        .alert("Rename Agent", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.rename(secret, to: newName) }
        } message: {
            Text("Your name stays when an agent connects through this address.")
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
