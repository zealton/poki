import PokiCore
import SwiftUI

// The app's three tabs (the owner's layout, Nov 7 2026):
// - Poki: every session, with Poki's state and controls on top; the button at the bottom left starts a
//   new chat with Poki's own agent.
// - Agents: the agents that drive this iPhone (their MCP addresses and the relay), Poki's own agent
//   (accounts, models, voice, memory) and the Activity Log.
// - Setup: everything Poki needs, read live, each item fixed on its own page; advanced preferences and
//   debugging tools behind the button at the top right.

/// Agents › a page.
enum AgentsRoute: Hashable { case accounts, voice, activityLog }

struct AgentsView: View {
    /// The line under MCP Relay: the address to set, Poki being off, or the relay's live state.
    private var relayLine: String {
        if model.relayAddress == nil { return String(localized: "Set an address first") }
        if !model.relayEnabled { return String(localized: "Off: agents can’t reach this iPhone") }
        if !model.sessionOn { return String(localized: "Waiting for Poki: turn Poki on and agents can connect") }
        return Health.relay(model).word
    }

    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    var openSession: (String) -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                Section {
                    AgentExecutionToggle()
                } header: {
                    Text("Execution")
                }
                Section {
                    NavigationLink(value: AgentsRoute.accounts) {
                        LabeledContent {
                            Text(ModelKeys.hasUsableKey ? ModelKeys.selectedModelName : String(localized: "Add an Account")).foregroundStyle(ModelKeys.hasUsableKey ? Color.secondary : Color.orange)
                        } label: { Label("Accounts and Models", systemImage: "person.crop.circle") }
                    }
                    NavigationLink(value: AgentsRoute.voice) {
                        LabeledContent {
                            Text(VoiceDirect.apiKey != nil ? VoiceDirect.model : String(localized: "Dictation Only"))
                        } label: { Label("Voice", systemImage: "waveform") }
                    }
                    NavigationLink(value: SettingsRoute.memory) {
                        LabeledContent {
                            Text("\(RoutineStore.shared.routines.count) routines")
                        } label: { Label("Memory", systemImage: "brain") }
                    }
                } header: {
                    Text("Poki Agent")
                } footer: {
                    Text("The model Poki’s chat and voice use on this iPhone. Memory holds the routines and notes every agent shares.")
                }

                Section {
                    ForEach(model.identity.secrets) { secret in
                        let last = SessionStore.shared.sessions(for: secret, among: model.identity.secrets).first
                        NavigationLink(value: SettingsRoute.connector(secret)) {
                            LabeledContent {
                                Text(last.map { ChatTime.row($0.updated) } ?? String(localized: "Not Used Yet"))
                            } label: {
                                Label {
                                    Text(verbatim: secret.name)
                                } icon: {
                                    // The agent that connected through it (or used it last).
                                    if let client = secret.agent ?? last?.client {
                                        AgentBadge(name: client, size: 28)
                                    } else {
                                        Image(systemName: "point.3.connected.trianglepath.dotted")
                                    }
                                }
                            }
                        }
                        .swipeActions { Button("Revoke", role: .destructive) { model.revoke(secret) } }
                    }
                    // A new connector is "Connector N" until an agent connects through it (or you
                    // name it on its page).
                    Button(action: add) {
                        Label {
                            Text("Add Agent")
                        } icon: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                        }
                    }
                    .disabled(model.relayAddress == nil)
                } header: {
                    Text("External Agents")
                } footer: {
                    Text(model.relayAddress == nil
                         ? "Set your relay first: each agent gets its own MCP address on it."
                         : "Each agent gets its own MCP address; add it as a remote MCP server in Claude, Codex or any MCP client. It takes the agent’s name and icon when the agent first connects, unless you renamed it. Swipe to revoke.")
                }

                Section {
                    // On or off; it can't be turned on before an address is set, and is on once one is.
                    Toggle(isOn: Binding(get: { model.relayEnabled && model.relayAddress != nil }, set: { model.setRelayEnabled($0) })) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("MCP Relay")
                                Text(relayLine)
                                    .font(.footnote).foregroundStyle(Color(.secondaryLabel))
                            }
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                    // Poki stopped: the switch keeps the owner's choice but is greyed, since nothing
                    // connects until Poki is on; the line under it says so.
                    .disabled(model.relayAddress == nil || !model.sessionOn)
                    NavigationLink(value: SettingsRoute.relay) {
                        LabeledContent {
                            Text(model.relayAddress.map { $0.origin.host() ?? $0.origin.absoluteString } ?? String(localized: "Not Set"))
                                .foregroundStyle(model.relayAddress == nil ? Color.orange : Color.secondary)
                        } label: {
                            Label("Address", systemImage: "network")
                        }
                    }
                } header: {
                    Text("MCP Relay")
                } footer: {
                    Text("The relay forwards agents’ requests to this iPhone while Poki is open or in the background. It stores nothing.")
                }

                Section {
                    Toggle("Ask Before Sensitive Steps", isOn: $model.askBeforeSensitiveSteps)
                } header: {
                    Text("Approvals")
                } footer: {
                    Text("Poki asks you before an agent pays, deletes, sends a message, places a call, types a password or does anything in Wallet: on the Live Activity, in a notification, or here in Poki. Turned off, agents do all of that without asking. Changes take effect the next time Poki opens.")
                }

                Section {
                    NavigationLink(value: AgentsRoute.activityLog) { Label("Activity Log", systemImage: "list.bullet.rectangle") }
                } footer: {
                    Text("Every action any agent ran on this iPhone. It can’t be deleted.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Agents")
            .navigationDestination(for: AgentsRoute.self) { route in
                switch route {
                case .accounts: ModelSettingsView()
                case .voice: VoiceView(embedded: true)
                case .activityLog: ActionLogView(openSession: openSession)
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
            }
        }
    }

    private func add() {
        guard model.relayAddress != nil else { return }
        let secret = model.addConnector(name: "")
        path.append(SettingsRoute.connector(secret))
    }
}

/// Setup: the live checklist, with Advanced behind the top-right button.
struct SetupTab: View {
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            SetupChecklist()
                .navigationTitle("Setup")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: SetupRoute.advanced) { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel(Text("Advanced"))
                    }
                }
                .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
                .navigationDestination(for: SetupRoute.self) { _ in AdvancedView(push: { path.append($0) }) }
                .navigationDestination(for: SettingsRoute.self) { route in
                    SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
                }
        }
    }
}

enum SetupRoute: Hashable { case advanced }

/// Setup › Advanced: preferences and debugging tools.
struct AdvancedView: View {
    @Environment(AppModel.self) private var model
    var push: (SettingsRoute) -> Void

    var body: some View {
        @Bindable var model = model
        Form {
            if model.automationPath == .runner {
                Section {
                    LabeledContent("Runner", value: Health.runner(model).word)
                    Picker("Stop When Idle For", selection: $model.idleStopSeconds) {
                        ForEach(SettingsHome.idleChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: { Text("Poki Runner") }
            }
            Section {
                Button("Notifications") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
                NavigationLink("Diagnostics", value: SettingsRoute.diagnostics)
                NavigationLink("Log", value: SettingsRoute.log)
                NavigationLink("Live Activity Preview", value: SettingsRoute.activityPreview)
            } footer: {
                Text("Diagnostics: connection checks, the background hold, this iPhone’s addresses and the in-process automation switch.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}
