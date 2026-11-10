// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

/// One owner preference for the app's chats and delegated Poki tasks.
@MainActor
@Observable
final class AgentExecutionSettings {
    static let shared = AgentExecutionSettings()
    static let key = "agent.backgroundExecution"

    private let defaults: UserDefaults
    private(set) var backgroundEnabled: Bool
    private var activeTasks: Set<UUID> = []
    var canChange: Bool { activeTasks.isEmpty }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        backgroundEnabled = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    @discardableResult
    func setBackgroundEnabled(_ enabled: Bool) -> Bool {
        guard canChange else { return false }
        backgroundEnabled = enabled
        defaults.set(enabled, forKey: Self.key)
        return true
    }

    func setRunning(_ running: Bool, task: UUID) {
        if running { activeTasks.insert(task) } else { activeTasks.remove(task) }
    }
}
