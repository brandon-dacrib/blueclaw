import SwiftUI

struct SessionRowView: View {
    let session: Session
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            // Agent indicator
            Circle()
                .fill(isSelected ? AppColors.accent : AppColors.surfaceLight)
                .frame(width: 36, height: 36)
                .overlay {
                    Text(agentEmoji)
                        .font(.system(size: 16))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                if let model = session.model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.accent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var isSelected: Bool {
        appState.activeSessionKey == session.key
    }

    private var agentEmoji: String {
        if let agentId = session.agentId,
           let agent = appState.agents.first(where: { $0.id == agentId }),
           let emoji = agent.emoji {
            return emoji
        }
        return "🤖"
    }
}
