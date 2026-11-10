import Foundation

/// Early observational learning: these are screen observations, not a claimed
/// recording of the user's touches. Raw field values live only in this task.
struct UserIntervention {
    var id: String
    var app: String?
    var before: [Element]
    var samples: Int = 0
    var capturedPausedBaseline = false
    var changedFields: Int = 0
    var visitedApps: Set<String> = []
}

extension Computer {
    func beginUserIntervention(_ h: Handoff) {
        intervention = UserIntervention(id: h.id, app: lastForeground?.bundleID,
                                       before: lastAll.filter(Self.learnableField))
        // The trace now has an unobserved manual gap. It must not be advertised as
        // a fully automatic success, even when routine creation is switched off.
        traceHasUserGap = true
    }

    static func learnableField(_ e: Element) -> Bool {
        !e.fromPicture && ["TextField", "TextView", "SearchField"].contains(e.type)
            && e.value != nil && !(e.identifier ?? "").isEmpty
            && !(e.identifier ?? "").lowercased().contains("password")
            && !(e.label ?? "").lowercased().contains("password")
    }

    /// Called only after the ordinary fresh screen read. No background keystroke
    /// logger, screenshots on disk, or inferred coordinate taps are introduced.
    func observeUserIntervention() -> String? {
        guard var record = intervention, let h = handoff.value, h.id == record.id else { return nil }
        let fields = lastAll.filter(Self.learnableField)
        record.samples += 1
        if !record.capturedPausedBaseline, h.done == nil {
            // The last automated screen may predate a partially committed type.
            // Start comparison at the first actual paused observation instead.
            record.before = fields
            record.capturedPausedBaseline = true
        }
        if let app = lastForeground?.bundleID { record.visitedApps.insert(app) }
        let changed = fields.filter { field in
            record.before.contains { $0.identifier == field.identifier && $0.type == field.type && $0.value != field.value }
        }
        record.changedFields = max(record.changedFields, changed.count)
        intervention = record
        guard h.done != nil else { return nil }
        defer { intervention = nil }
        let sameApp = record.app == lastForeground?.bundleID
        let summary = "User intervention: \(record.samples) observed screens, \(record.visitedApps.count) apps, \(record.changedFields) changed identifiable text fields; \(sameApp ? "returned to the same app" : "moved to another app"). Manual touches and intent were not inferred."
        _ = memory?.remember(summary, by: "user-intervention")
        if config.userRoutineLearning() {
            if record.capturedPausedBaseline, sameApp, record.visitedApps.count <= 1, changed.count == 1, let field = changed.first,
               let text = field.value, text.count <= 2000,
               fields.filter({ $0.identifier == field.identifier }).count == 1 {
                // Record the observed final replacement, not an invented series
                // of deletes/keystrokes. It remains a user-assisted checkpoint.
                let step = RoutineStep(action: ["type": .string(text), "clear": true, "ref": "@"],
                    target: RoutineTarget(field), app: lastForeground?.bundleID, secret: nil,
                    userDemonstrated: true)
                trace.append(RecordedStep(step: step, typed: text, keysBefore: Set(record.before.map(\.key))))
            } else {
                let step = RoutineStep(action: ["handoff": ["kind": "other", "text": "Repeat the manual navigation or correction demonstrated here, then tap Done."]],
                    target: nil, app: record.app, secret: nil, userDemonstrated: true)
                trace.append(RecordedStep(step: step, typed: nil, keysBefore: []))
            }
        }
        return "learn: \(summary) Compare the current screen with the state before takeover. The user may have corrected text, advanced the task, or done something unrelated: do not assume which. Continue from their current state, never replay the unfinished input. Save only evidence-backed lessons with routines {action: remember}; ask about ambiguous intent."
    }
}
