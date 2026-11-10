import Foundation

/// The models each account offers the text chat: a few fast defaults per type (no-thinking models such
/// as GPT-6.1 Terra and Claude Haiku first), plus whatever the provider's own model list returns for
/// the owner's key, which start switched off. The owner switches models on and off in Accounts ›
/// the account › Text Chat; the chat's model menu offers only the ones switched on.
enum ModelCatalog {
    /// The defaults, switched on until the owner turns them off.
    static func defaults(_ provider: ModelProvider) -> Set<String> {
        switch provider {
        case .anthropic: ["claude-haiku-5-5", "claude-sonnet-5-5"]
        case .openai, .chatgpt: ["gpt-6.1-terra"]
        case .deepseek: ["deepseek-flash"]
        case .gemini: ["gemini-3.8-flash"]
        case .openrouter: [OpenRouterDefaults.modelID]
        case .custom: Set(provider.models.map(\.id))
        }
    }

    /// The account's models: the built-in ones, fast first, then the listed ones.
    static func all(_ provider: ModelProvider) -> [ChatModelChoice] {
        let builtIn = provider.models.sorted { fast($0.id) && !fast($1.id) }
        let known = Set(builtIn.map(\.id))
        return builtIn + listed(provider).filter { !known.contains($0.id) }
    }

    static func available(_ provider: ModelProvider) -> [ChatModelChoice] {
        let on = enabled(provider)
        return all(provider).filter { on.contains($0.id) }
    }

    static func enabled(_ provider: ModelProvider) -> Set<String> {
        if let saved = UserDefaults.standard.stringArray(forKey: "models.enabled.\(provider.rawValue)") { return Set(saved) }
        return defaults(provider)
    }

    static func set(_ id: String, on: Bool, for provider: ModelProvider) {
        var ids = enabled(provider)
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: "models.enabled.\(provider.rawValue)")
        // The chat's model is always one that is switched on.
        if ModelKeys.selectedProvider == provider, !ids.contains(ModelKeys.selectedModel), let first = available(provider).first {
            ModelKeys.selectedModel = first.id
        }
        ModelKeys.saved += 1
    }

    static func listed(_ provider: ModelProvider) -> [ChatModelChoice] {
        (UserDefaults.standard.stringArray(forKey: "models.listed.\(provider.rawValue)") ?? []).map { ChatModelChoice(id: $0, name: $0) }
    }

    /// No-thinking, fast models first: Terra, Haiku, Flash.
    static func fast(_ id: String) -> Bool {
        ["terra", "haiku", "flash", "mini"].contains { id.lowercased().contains($0) }
    }

    /// Reads the provider's model list with the owner's key (sent only to that provider).
    static func refresh(_ provider: ModelProvider) async throws -> Int {
        guard let request = request(provider) else { return 0 }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        var ids = items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .filter { usable($0, provider) }
        if provider == .openai {
            let voice = items.compactMap { $0["id"] as? String }.filter { $0.contains("realtime") && !$0.contains("transcribe") }.sorted()
            UserDefaults.standard.set(voice, forKey: "models.listed.voice")
        }
        ids = Array(Set(ids)).sorted { fast($0) == fast($1) ? $0 < $1 : fast($0) }
        UserDefaults.standard.set(ids, forKey: "models.listed.\(provider.rawValue)")
        ModelKeys.saved += 1
        return ids.count
    }

    /// Chat models only: no embeddings, speech, images or moderation.
    private static func usable(_ id: String, _ provider: ModelProvider) -> Bool {
        let lower = id.lowercased()
        let skip = ["embed", "audio", "realtime", "transcribe", "tts", "whisper", "image", "dall-e", "moderation", "search", "aqa", "imagen", "veo"]
        if skip.contains(where: lower.contains) { return false }
        switch provider {
        case .openai: return lower.hasPrefix("gpt-") || lower.hasPrefix("o")
        case .anthropic: return lower.hasPrefix("claude")
        case .gemini: return lower.hasPrefix("gemini")
        default: return true
        }
    }

    private static func request(_ provider: ModelProvider) -> URLRequest? {
        let key = ModelKeys.key(provider)
        var request: URLRequest
        switch provider {
        case .openai:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .deepseek:
            guard let key else { return nil }
            request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            guard let key, var parts = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else { return nil }
            parts.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "pageSize", value: "200")]
            request = URLRequest(url: parts.url!)
        case .openrouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .custom:
            let base = ModelKeys.customURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: base)?.appending(path: "models") else { return nil }
            request = URLRequest(url: url)
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .chatgpt:
            // A ChatGPT sign-in has no model list; its plan's models are the built-in ones.
            return nil
        }
        request.timeoutInterval = 15
        return request
    }

    // MARK: Voice

    /// Live voice models (OpenAI Realtime): the built-in one and any the key's list adds, off at first.
    static let voiceDefault = "gpt-realtime-2.1"

    static var voiceAll: [ChatModelChoice] {
        let listed = (UserDefaults.standard.stringArray(forKey: "models.listed.voice") ?? []).filter { $0 != voiceDefault }
        return [ChatModelChoice(id: voiceDefault, name: "GPT Realtime 2.1")] + listed.map { ChatModelChoice(id: $0, name: $0) }
    }

    static var voiceEnabled: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "models.enabled.voice") ?? [voiceDefault])
    }

    static func setVoice(_ id: String, on: Bool) {
        var ids = voiceEnabled
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids), forKey: "models.enabled.voice")
        if !ids.contains(voiceModel) { voiceModel = voiceAll.first { ids.contains($0.id) }?.id ?? voiceDefault }
        ModelKeys.saved += 1
    }

    static var voiceAvailable: [ChatModelChoice] { voiceAll.filter { voiceEnabled.contains($0.id) } }

    /// The live voice model.
    static var voiceModel: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "voice.model") ?? voiceDefault
            return voiceEnabled.contains(saved) ? saved : voiceAvailable.first?.id ?? voiceDefault
        }
        set { UserDefaults.standard.set(newValue, forKey: "voice.model"); ModelKeys.saved += 1 }
    }
}
