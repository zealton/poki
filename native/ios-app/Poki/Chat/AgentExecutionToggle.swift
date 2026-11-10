// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// The same global preference in chat and the Agent settings page.
struct AgentExecutionToggle: View {
    @Environment(ChatModel.self) private var chat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: Binding(get: { chat.carPlay }, set: chat.setCarPlay)) {
                Label("Run Agent in Background", systemImage: "square.stack")
                    .font(.subheadline.weight(.medium))
            }
            .disabled(!chat.canChangeExecutionMode)
            .accessibilityIdentifier("agent.backgroundExecution")
            Text(status)
                .font(.caption)
                .foregroundStyle(chat.carPlay && !chat.carPlayAvailable ? Color.orange : Color.secondary)
                .accessibilityIdentifier("agent.executionStatus")
        }
    }

    private var status: String {
        if !chat.canChangeExecutionMode {
            return String(localized: "Wait for the current task to finish before changing this.")
        }
        if chat.carPlay {
            return chat.carPlayAvailable
                ? String(localized: "Use other apps while Poki works. You can watch its actions in the preview.")
                : String(localized: "Background execution is not available here yet. Turn this off to use Poki’s original mode.")
        }
        return String(localized: "Poki uses its original mode and may switch apps or use the keyboard.")
    }
}
