import Foundation
import PiSwiftAI

/// The model providers the chat can use with the owner's own key or account (ESP-171 board "M Model").
/// The wired ones run through pi (PiLoop); the others store their key and address for a later step.
enum ModelProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openai, chatgpt, deepseek, gemini, openrouter, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .chatgpt: "ChatGPT"
        case .deepseek: "DeepSeek"
        case .gemini: "Gemini"
        case .openrouter: "OpenRouter"
        case .custom: String(localized: "Custom Endpoint")
        }
    }

    /// The letter on the coloured tile, and the tile's colour (from the board).
    var mark: String {
        switch self {
        case .anthropic: "A"
        case .openai: "O"
        case .chatgpt: "C"
        case .deepseek: "D"
        case .gemini: "G"
        case .openrouter: "R"
        case .custom: "{ }"
        }
    }

    var tile: UInt32 {
        switch self {
        case .anthropic: 0xD97757
        case .openai: 0x111111
        case .chatgpt: 0x10A37F
        case .deepseek: 0x4D6BFE
        case .gemini: 0x4285F4
        case .openrouter: 0x6566F1
        case .custom: 0x8E8E93
        }
    }

    /// pi's provider id (PiSwiftAI's catalog).
    var piProvider: String? {
        switch self {
        case .anthropic: "anthropic"
        case .openai: "openai"
        // Sign in with ChatGPT (OpenAI's open-source flow) runs on the OpenAI API with the plan's token.
        case .chatgpt: "openai"
        case .deepseek: "deepseek"
        case .gemini: "google"
        case .openrouter: "openrouter"
        case .custom: "poki-custom"
        }
    }

    /// The chat runs on this provider today (all of them, through pi).
    var wired: Bool { piProvider != nil }

    /// ChatGPT is an account the owner signs in to; the others take a key.
    var signsIn: Bool { self == .chatgpt }

    /// What a key looks like, for the field's placeholder.
    var keyPrompt: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai, .deepseek: "sk-…"
        case .chatgpt: ""
        case .gemini: "AIza…"
        case .openrouter: "sk-or-…"
        case .custom: String(localized: "API key, if it needs one")
        }
    }

    var models: [ChatModelChoice] {
        switch self {
        case .anthropic: [
            ChatModelChoice(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
            ChatModelChoice(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
            ChatModelChoice(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
        ]
        // GPT-6.1 Terra first, the owner's choice for the chat (ESP-174); Sol stays selectable.
        case .openai: [
            ChatModelChoice(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
            ChatModelChoice(id: "gpt-6.1-sol", name: "GPT-6.1 Sol"),
        ]
        // The ChatGPT plan's models on the OpenAI API; gpt-6.1-terra is also Poki
        // Agent's default on the Mac (agent/model-config.mjs).
        case .chatgpt: [
            ChatModelChoice(id: "gpt-6.1-terra", name: "ChatGPT GPT-6.1 Terra"),
            ChatModelChoice(id: "gpt-6.1-sol", name: "ChatGPT GPT-6.1 Sol"),
        ]
        // DeepSeek's current names (api-docs.deepseek.com, 2026-11-07); deepseek-chat is retired. V4 Pro
        // reads text only, so it does not see the screenshots.
        case .deepseek: [
            ChatModelChoice(id: "deepseek-flash", name: "DeepSeek V4.1 Flash"),
            ChatModelChoice(id: "deepseek-v4-pro", name: String(localized: "DeepSeek V4 Pro (no screenshots)")),
        ]
        // pi's google provider (Gemini API), both reading screenshots.
        case .gemini: [
            ChatModelChoice(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
            ChatModelChoice(id: "gemini-4-argon", name: "Gemini 4 Argon"),
        ]
        // One OpenRouter key, the main labs' models (PiSwift's openrouter catalog).
        case .openrouter: [
            ChatModelChoice(id: OpenRouterDefaults.modelID, name: "DeepSeek V4.1 Flash (OpenRouter)"),
            ChatModelChoice(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5 (OpenRouter)"),
            ChatModelChoice(id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5 (OpenRouter)"),
            ChatModelChoice(id: "openai/gpt-6.1-sol", name: "GPT-6.1 Sol (OpenRouter)"),
            ChatModelChoice(id: "google/gemini-3.8-flash", name: "Gemini 3.8 Flash (OpenRouter)"),
        ]
        // Whatever model the owner's endpoint serves (a local server, a company gateway).
        case .custom:
            ModelKeys.customModel.isEmpty ? [] : [ChatModelChoice(id: ModelKeys.customModel, name: ModelKeys.customModel)]
        }
    }

    /// Where the owner creates a key.
    var keyHelp: String {
        switch self {
        // Claude.ai sign-in is for Anthropic's own apps only; Max and Team plans include monthly API credits.
        case .anthropic: String(localized: "Create a key at console.anthropic.com, then paste it here. On a Claude Max or Team plan, first claim your plan’s monthly API credits in claude.ai › Settings › Billing, so the key uses them.")
        case .openai: String(localized: "Create a key at platform.openai.com, then paste it here.")
        case .deepseek: String(localized: "Create a key at platform.deepseek.com, then paste it here.")
        case .gemini: String(localized: "Create a key at aistudio.google.com, then paste it here.")
        case .openrouter: String(localized: "Create a key at openrouter.ai/keys, then paste it here.")
        case .custom: String(localized: "Any server that speaks the OpenAI chat completions API. Poki sends the key, if any, only to this address.")
        default: ""
        }
    }

    /// pi's model for one of `models`.
    func piModel(_ id: String) -> Model? {
        guard let piProvider else { return nil }
        if self == .openrouter, id == OpenRouterDefaults.modelID {
            // Explicit metadata: do not inherit another lab's API or vision capabilities when
            // PiSwift's pinned catalog predates this model. Uses the same PokiCore tools as before.
            return Model(id: id, name: "DeepSeek V4.1 Flash (OpenRouter)", api: .openAICompletions,
                         provider: piProvider, baseUrl: OpenRouterDefaults.baseURL, reasoning: true,
                         input: [.text, .image],
                         cost: ModelCost(input: 0.006, output: 0.5, cacheRead: 0.005, cacheWrite: 0),
                         contextWindow: 1_048_576, maxTokens: 8_192)
        }
        if self == .custom {
            let base = ModelKeys.customURL.trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty, !id.isEmpty else { return nil }
            return Model(id: id, name: id, api: .openAICompletions, provider: piProvider, baseUrl: base, reasoning: false,
                         input: [.text, .image], cost: ModelCost(input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
                         contextWindow: 128_000, maxTokens: 8_192)
        }
        if let model = getModel(provider: piProvider, modelId: id) { return model }
        // PiSwift's catalog (pi-mono, October 2026) lacks gpt-6.1-terra, which pi-ai 1.5.0 lists with the
        // same API and inputs as gpt-6.1-sol.
        // A model from the provider's own list that pi's catalog lacks takes the shape of a built-in one of
        // the same provider (same API and inputs), with its own id.
        let template = (self == .openai || self == .chatgpt) && id == "gpt-6.1-terra" ? "gpt-6.1-sol" : models.lazy.compactMap { getModel(provider: piProvider, modelId: $0.id) }.first?.id
        guard let template, let base = getModel(provider: piProvider, modelId: template),
              var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base))) as? [String: Any] else { return nil }
        json["id"] = id
        json["name"] = id == "gpt-6.1-terra" ? "GPT-6.1 Terra" : id
        return (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(Model.self, from: $0) }
    }
}

struct ChatModelChoice: Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

/// This fork's default account. Credentials still come only from the owner's Keychain.
enum OpenRouterDefaults {
    static let baseURL = "https://openrouter.ai/api/v1"
    static let modelID = "deepseek/deepseek-v4.1-flash-1017"
}

/// The owner's keys and the ChatGPT sign-in, in this iPhone's keychain (the relay key's service, one
/// account per provider). A key is only ever sent to its own provider. Nothing here prints or logs a key
/// or a token.
enum ModelKeys {
    private static func account(_ provider: ModelProvider) -> String { "model-key.\(provider.rawValue)" }

    #if DEBUG && targetEnvironment(simulator)
    private static let volatileLock = NSLock()
    nonisolated(unsafe) private static var volatileKeys: [ModelProvider: String] = [:]
    #endif

    /// Unsigned Simulator builds may lack Keychain entitlement. Their explicit fallback lives only
    /// in this process and is labelled in Accounts; device/release builds always require Keychain.
    static func isMemoryOnly(_ provider: ModelProvider) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        return volatileLock.withLock { volatileKeys[provider] != nil }
        #else
        return false
        #endif
    }

    static func key(_ provider: ModelProvider) -> String? {
        #if DEBUG && targetEnvironment(simulator)
        if let key = volatileLock.withLock({ volatileKeys[provider] }) { return key }
        #endif
        guard let data = try? Keychain.read(account(provider)), let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func hasKey(_ provider: ModelProvider) -> Bool { key(provider) != nil }

    static func save(_ key: String, for provider: ModelProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG && targetEnvironment(simulator)
        do {
            try Keychain.write(Data(trimmed.utf8), account: account(provider))
            volatileLock.withLock { volatileKeys.removeValue(forKey: provider) }
        } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == -34018 {
            volatileLock.withLock { volatileKeys[provider] = trimmed }
        }
        #else
        try Keychain.write(Data(trimmed.utf8), account: account(provider))
        #endif
        saved += 1
    }

    static func remove(_ provider: ModelProvider) {
        #if DEBUG && targetEnvironment(simulator)
        volatileLock.withLock { volatileKeys.removeValue(forKey: provider) }
        #endif
        Keychain.delete(account(provider))
        saved += 1
    }

    /// The custom endpoint's address (not a secret: kept in the app's settings).
    static var customURL: String {
        get { UserDefaults.standard.string(forKey: "chat.customURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "chat.customURL") }
    }

    /// The custom endpoint's model id.
    static var customModel: String {
        get { UserDefaults.standard.string(forKey: "chat.customModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "chat.customModel") }
    }

    /// The chat can run: the chosen provider is wired and has a key (a custom endpoint: an address and a
    /// model; its key is optional).
    static var hasUsableKey: Bool {
        if selectedProvider == .custom { return !customURL.isEmpty && !customModel.isEmpty }
        if selectedProvider == .chatgpt { return ChatGPTAccount.signedIn }
        return selectedProvider.wired && hasKey(selectedProvider)
    }

    static var selectedProvider: ModelProvider {
        get { UserDefaults.standard.string(forKey: "chat.provider").flatMap(ModelProvider.init(rawValue:)) ?? .openrouter }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "chat.provider"); saved += 1 }
    }

    /// Each provider's model: its first (Claude Sonnet 5.5, GPT-6.1 Terra) unless the owner picks another.
    static func model(for provider: ModelProvider) -> String {
        let saved = UserDefaults.standard.string(forKey: "chat.model.\(provider.rawValue)")
        let available = ModelCatalog.available(provider)
        return saved.flatMap { id in available.contains { $0.id == id } ? id : nil } ?? available.first?.id ?? provider.models.first?.id ?? ""
    }

    static var selectedModel: String {
        get { model(for: selectedProvider) }
        set { UserDefaults.standard.set(newValue, forKey: "chat.model.\(selectedProvider.rawValue)") }
    }

    static var selectedModelName: String {
        ModelCatalog.all(selectedProvider).first { $0.id == selectedModel }?.name ?? selectedModel
    }

    /// Bumped on every change, so views that read keys can redraw; `changed` is posted too (ask_poki is
    /// listed for outside agents only while a model is set up).
    nonisolated(unsafe) static var saved = 0 { didSet { NotificationCenter.default.post(name: changed, object: nil) } }
    static let changed = Notification.Name("PokiModelKeysChanged")
}

/// The credential pi sends for a provider: the key, or for ChatGPT the signed-in access token, refreshed
/// a minute before it runs out (pi's rule; `expires` is in milliseconds).
enum ModelCredential {
    static func apiKey(for provider: ModelProvider) async -> String? {
        // A custom endpoint may need no key; the request still carries one.
        guard let stored = ModelKeys.key(provider) else { return provider == .custom ? "none" : nil }
        guard provider.signsIn else { return stored }
        // A sign-in from OpenAI's open-source flow carries its issued client id; an older Codex-client
        // sign-in does not, and has to be done again.
        guard var credentials = ChatGPTAccount.decode(stored), credentials.clientId?.isEmpty == false else { return nil }
        if credentials.expires < Date().timeIntervalSince1970 * 1000 + 60_000, !credentials.refresh.isEmpty {
            guard let fresh = try? await refreshOpenAIChatGPTToken(credentials) else { return nil }
            credentials = fresh
            try? ChatGPTAccount.save(credentials)
        }
        return credentials.access
    }
}
