// The model page combines two files from lhuanyu/OllamaMessage (commit c857a02), Copyright (c) 2023
// Huanyu Luo, MIT License; see THIRD_PARTY_NOTICES.md:
// - OllamaMessage/Class/View/MessageList/DialogueSettingsView.swift: the "Model" row with its label and a hidden-label
//   Picker on the right;
// - OllamaMessage/Class/View/DialogueList/OllamaModelSelectionView.swift: one row per provider with its 30 pt icon, the
//   whole row tappable, and the footer under the list.
// Changed: the ESP-171 board "M Model" (the grouped rows, the provider tiles, "Add Key"), keys entered
// into the keychain instead of a server's model list, and the agents on a computer below.
import SwiftUI

/// Accounts, as the Mail app lists mail accounts: every model account on this iPhone whatever its
/// provider, each with what it is used for (the text chat, live voice) switched on or off inside it.
/// What an account can power is worked out from its type: any wired provider can run the text chat;
/// live voice needs OpenAI's Realtime API, so only an OpenAI API key can run it.
struct ModelSettingsView: View {
    @State private var adding = false
    @State private var version = ModelKeys.saved

    var body: some View {
        List {
            Section {
                ForEach(ModelProvider.allCases.filter(ModelAccounts.isSetUp)) { provider in
                    NavigationLink { AccountDetail(provider: provider) } label: { AccountRow(provider: provider) }
                }
                Button("Add Account", systemImage: "plus") { adding = true }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Keys and sign-ins stay in this iPhone’s Keychain. Poki sends each one only to its own provider.")
            }

            Section {
                LabeledContent("Text Chat", value: ModelKeys.hasUsableKey ? "\(ModelKeys.selectedProvider.name), \(ModelKeys.selectedModelName)" : String(localized: "No Account"))
                LabeledContent("Live Voice", value: VoiceDirect.apiKey != nil ? String(localized: "OpenAI") : String(localized: "No Account"))
                LabeledContent("Dictation", value: String(localized: "On This iPhone"))
            } header: {
                Text("In Use")
            } footer: {
                Text("Open an account to choose what it is used for. Dictation in the message field needs no account.")
            }

        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .listStyle(.insetGrouped)
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .sheet(isPresented: $adding) { AddAccount() }
    }
}

/// What a model account is and what it can power.
enum ModelAccounts {
    static func isSetUp(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .custom: !ModelKeys.customURL.isEmpty
        case .chatgpt: ChatGPTAccount.signedIn
        default: ModelKeys.hasKey(provider)
        }
    }

    static func canChat(_ provider: ModelProvider) -> Bool { provider.wired }
    /// Live voice is OpenAI's Realtime API: an OpenAI API key only (a ChatGPT sign-in can't open it).
    static func canTalkLive(_ provider: ModelProvider) -> Bool { provider == .openai }

    static func method(_ provider: ModelProvider) -> String {
        switch provider {
        case .chatgpt: String(localized: "Sign in with ChatGPT")
        case .custom: String(localized: "OpenAI-compatible address")
        default: String(localized: "API key")
        }
    }

    /// "Text Chat, Live Voice", "Not in use".
    static func uses(_ provider: ModelProvider) -> String {
        var out: [String] = []
        if ModelKeys.selectedProvider == provider, ModelKeys.hasUsableKey { out.append(String(localized: "Text Chat")) }
        if canTalkLive(provider), VoiceDirect.apiKey != nil { out.append(String(localized: "Live Voice")) }
        return out.isEmpty ? String(localized: "Not in use") : out.joined(separator: ", ")
    }
}

private struct AccountRow: View {
    var provider: ModelProvider
    var body: some View {
        HStack(spacing: 12) {
            ProviderTile(provider: provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: provider.name)
                Text(ModelAccounts.uses(provider)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}

/// One account: its type and connection, what it is used for (switches; the ones it can't power are
/// shown greyed with why), its model, and Delete.
private struct AccountDetail: View {
    @Environment(\.dismiss) private var dismiss
    var provider: ModelProvider
    @State private var editing = false
    @State private var signingIn = false
    @State private var version = ModelKeys.saved

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: provider.name)
                LabeledContent("Connection", value: ModelAccounts.method(provider))
                if ModelKeys.isMemoryOnly(provider) {
                    Text("Simulator: key is kept only until Poki exits. Enter it again after relaunch.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if provider == .custom { LabeledContent("Address", value: ModelKeys.customURL) }
                Button(provider.signsIn ? "Sign In Again" : provider == .custom ? "Edit Address and Key" : "Replace Key") {
                    if provider.signsIn { signingIn = true } else { editing = true }
                }
            }

            Section {
                NavigationLink { TextChatFeature(provider: provider) } label: {
                    LabeledContent {
                        Text(ModelKeys.selectedProvider == provider ? ModelKeys.selectedModelName : ModelAccounts.canChat(provider) ? String(localized: "Off") : String(localized: "Not Supported"))
                    } label: { Label("Text Chat", systemImage: "bubble.left.and.text.bubble.right") }
                }
                .disabled(!ModelAccounts.canChat(provider))
                NavigationLink { LiveVoiceFeature() } label: {
                    LabeledContent {
                        Text(ModelAccounts.canTalkLive(provider) ? (VoiceDirect.enabled ? VoiceDirect.model : String(localized: "Off")) : String(localized: "Not Supported"))
                    } label: { Label("Live Voice", systemImage: "waveform") }
                }
                .disabled(!ModelAccounts.canTalkLive(provider))
            } header: {
                Text("Use This Account For")
            } footer: {
                if !ModelAccounts.canChat(provider) {
                    Text("Poki keeps this key; chatting with \(provider.name) comes in an update.")
                } else if !ModelAccounts.canTalkLive(provider) {
                    Text("Live voice runs on OpenAI’s Realtime API, which only an OpenAI API key can open. Dictation in the message field works with this account.")
                }
            }

            Section {
                Button(provider.signsIn ? "Sign Out" : "Delete Account", role: .destructive) {
                    if provider == .custom { ModelKeys.customURL = ""; ModelKeys.customModel = "" }
                    ModelKeys.remove(provider)
                    if ModelKeys.selectedProvider == provider, let other = ModelProvider.allCases.first(where: { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) {
                        ModelKeys.selectedProvider = other
                    }
                    dismiss()
                }
            }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .navigationTitle(Text(verbatim: provider.name))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .sheet(isPresented: $editing, onDismiss: { version = ModelKeys.saved }) { KeyEntry(provider: provider) }
        .sheet(isPresented: $signingIn, onDismiss: { version = ModelKeys.saved }) { ChatGPTSignIn() }
    }
}

/// Account › Text Chat: whether this account runs the chat, its model, and which of its models the
/// chat's model menu offers.
private struct TextChatFeature: View {
    var provider: ModelProvider
    @State private var version = ModelKeys.saved
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Use for Text Chat", isOn: Binding(get: { ModelKeys.selectedProvider == provider }, set: { on in
                    if on { ModelKeys.selectedProvider = provider }
                    else if let other = ModelProvider.allCases.first(where: { $0 != provider && ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) {
                        ModelKeys.selectedProvider = other
                    }
                }))
                if ModelKeys.selectedProvider == provider {
                    Picker("Chat Model", selection: Binding(get: { ModelKeys.selectedModel }, set: { ModelKeys.selectedModel = $0; ModelKeys.saved += 1 })) {
                        ForEach(ModelCatalog.available(provider)) { Text($0.name).tag($0.id) }
                    }
                }
            } footer: {
                Text("Only one account runs the text chat at a time.")
            }
            Section {
                ForEach(ModelCatalog.all(provider)) { choice in
                    Toggle(isOn: Binding(get: { ModelCatalog.enabled(provider).contains(choice.id) }, set: { ModelCatalog.set(choice.id, on: $0, for: provider) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.name)
                            if ModelCatalog.fast(choice.id) { Text("Fast").font(.caption).foregroundStyle(Color(.secondaryLabel)) }
                        }
                    }
                }
                if provider != .chatgpt {
                    Button(loading ? "Reading the Model List…" : "Refresh Model List") { refresh() }.disabled(loading)
                }
            } header: {
                Text("Models to Choose From")
            } footer: {
                Text(problem ?? String(localized: "Fast models without long thinking answer quickest on the phone. Models from \(provider.name)’s list start switched off."))
            }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .navigationTitle("Text Chat")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
        .task { if ModelCatalog.listed(provider).isEmpty, provider != .chatgpt { refresh() } }
    }

    private func refresh() {
        loading = true
        problem = nil
        Task {
            do { _ = try await ModelCatalog.refresh(provider) } catch { problem = String(localized: "\(provider.name) didn’t return its model list. The built-in models still work.") }
            loading = false
        }
    }
}

/// Account › Live Voice (OpenAI only): on or off, the voice model, and which voice models to offer.
private struct LiveVoiceFeature: View {
    @State private var version = ModelKeys.saved

    var body: some View {
        Form {
            Section {
                Toggle("Use for Live Voice", isOn: Binding(get: { VoiceDirect.enabled }, set: { VoiceDirect.enabled = $0 }))
                if VoiceDirect.enabled {
                    Picker("Voice Model", selection: Binding(get: { ModelCatalog.voiceModel }, set: { ModelCatalog.voiceModel = $0 })) {
                        ForEach(ModelCatalog.voiceAvailable) { Text($0.name).tag($0.id) }
                    }
                }
            } footer: {
                Text("Live voice is a spoken conversation with OpenAI’s Realtime model: it listens, taps and types, and answers out loud.")
            }
            Section {
                ForEach(ModelCatalog.voiceAll) { choice in
                    Toggle(choice.name, isOn: Binding(get: { ModelCatalog.voiceEnabled.contains(choice.id) }, set: { ModelCatalog.setVoice(choice.id, on: $0) }))
                }
            } header: {
                Text("Voice Models to Choose From")
            } footer: {
                Text("Refresh the model list under Text Chat to add the other Realtime models your key can use.")
            }
        }
        // Reads the version so the page redraws with the new keys and models, without rebuilding it
        // (a rebuild dropped taps and the sheets it was presenting).
        .background { Color.clear.accessibilityHidden(true).id(version) }
        .navigationTitle("Live Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in version = ModelKeys.saved }
    }
}

/// Add Account: the account types, each with how it connects; choosing one opens its key, address or
/// sign-in.
private struct AddAccount: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ModelProvider?
    @State private var signingIn = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelProvider.allCases) { provider in
                        Button { if provider.signsIn { signingIn = true } else { editing = provider } } label: {
                            HStack(spacing: 12) {
                                ProviderTile(provider: provider)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: provider.name).foregroundStyle(Color(.label))
                                    Text(capabilities(provider)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                                }
                                Spacer()
                                if ModelAccounts.isSetUp(provider) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } footer: {
                    Text("Text chat works with every account. Live voice needs an OpenAI API key.")
                }
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $editing, onDismiss: { if editing == nil { dismiss() } }) { provider in KeyEntry(provider: provider) }
            .sheet(isPresented: $signingIn, onDismiss: { if ChatGPTAccount.signedIn { dismiss() } }) { ChatGPTSignIn() }
        }
    }

    private func capabilities(_ provider: ModelProvider) -> String {
        let how = ModelAccounts.method(provider)
        if ModelAccounts.canTalkLive(provider) { return String(localized: "\(how) · Text chat and live voice") }
        if ModelAccounts.canChat(provider) { return String(localized: "\(how) · Text chat") }
        return String(localized: "\(how) · Coming in an update")
    }
}

/// Entering, replacing or removing one provider's key. The field is secure and the key is never shown
/// again after it is saved.
private struct KeyEntry: View {
    @Environment(\.dismiss) private var dismiss
    var provider: ModelProvider
    @State private var key = ""
    @State private var url = ModelKeys.customURL
    @State private var modelID = ModelKeys.customModel
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                if provider == .custom {
                    Section {
                        TextField("https://…/v1", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Model, such as llama-4-maverick", text: $modelID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Address and model") }
                }
                Section {
                    SecureField(provider.keyPrompt, text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("\(provider.name) key")
                } footer: {
                    if !provider.wired {
                        Text("Poki keeps the key now; chatting with \(provider.name) comes in an update. Until then, choose Anthropic or OpenAI.")
                    } else if ModelKeys.hasKey(provider) {
                        Text("A key is saved. Enter a new one to replace it.")
                    } else {
                        Text(verbatim: provider.keyHelp)
                    }
                }
                if failed { Text("The keychain did not take the key. Try again.").foregroundStyle(Color(.systemRed)) }
                if ModelKeys.hasKey(provider) {
                    Section { Button("Remove Key", role: .destructive) { ModelKeys.remove(provider); dismiss() } }
                }
            }
            .navigationTitle(Text(verbatim: provider.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
        }
    }

    private var canSave: Bool {
        provider == .custom ? URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true && !modelID.trimmingCharacters(in: .whitespaces).isEmpty : !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        do {
            if provider == .custom {
                ModelKeys.customURL = url.trimmingCharacters(in: .whitespaces)
                ModelKeys.customModel = modelID.trimmingCharacters(in: .whitespaces)
                if key.isEmpty { ModelKeys.selectedProvider = .custom }
            }
            if !key.isEmpty { try ModelKeys.save(key, for: provider) }
            // A new key picks its provider; the model page's picker switches between providers with keys.
            if provider.wired, !key.isEmpty {
                // Ready at once: chat on this account's first fast model, live voice on where it can.
                ModelKeys.selectedProvider = provider
                if let first = ModelCatalog.available(provider).first { ModelKeys.selectedModel = first.id }
                if provider == .openai { VoiceDirect.enabled = true }
                Task { _ = try? await ModelCatalog.refresh(provider) }
            }
            key = ""
            dismiss()
        } catch {
            failed = true
        }
    }
}
