import Foundation

/// A copy of the owner's settings in the Keychain, so they survive an update, a reinstall or a
/// sideloading tool that re-signs the app with a fresh container (UserDefaults lives in the container;
/// Keychain items outlive it). At launch, any setting missing from UserDefaults is put back from the
/// copy; while Poki runs, every change to a setting rewrites the copy. Development switches (`poki…`
/// launch arguments) are never kept.
enum SettingsVault {
    private static let account = "settings.v1"
    /// The settings kept: exact keys and prefixes.
    private static let keys: Set<String> = ["setup", "relayAddress", "relayEnabled", "voiceBridge", "wantsOn", "automationPath", "chatEngine", "agent.backgroundExecution"]
    private static let prefixes = ["chat.", "voice.", "models.", "idleStopSeconds"]

    private static func kept(_ key: String) -> Bool { keys.contains(key) || prefixes.contains { key.hasPrefix($0) } }

    /// Puts back every kept setting UserDefaults does not have.
    static func restore() {
        guard let data = try? Keychain.read(account),
              let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        var restored = 0
        for (key, value) in saved where kept(key) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            restored += 1
        }
        if restored > 0 { NSLog("Poki: restored %d settings from the Keychain", restored) }
    }

    /// The current kept settings, written to the Keychain.
    static func save() {
        let all = UserDefaults.standard.dictionaryRepresentation().filter { kept($0.key) }
        guard !all.isEmpty, let data = try? PropertyListSerialization.data(fromPropertyList: all, format: .binary, options: 0) else { return }
        if (try? Keychain.read(account)) != data { try? Keychain.write(data, account: account) }
    }

    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    nonisolated(unsafe) private static var pending: DispatchWorkItem?

    /// Saves a second after the last change to UserDefaults, and once now.
    static func watch() {
        save()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            pending?.cancel()
            let work = DispatchWorkItem { save() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }
}
