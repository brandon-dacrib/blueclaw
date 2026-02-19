import SwiftUI

struct AgentPickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Menu {
            ForEach(appState.agents) { agent in
                Button {
                    appState.selectedAgent = agent
                    appState.startNewChat()
                } label: {
                    HStack {
                        Text(agent.displayName)
                        if agent.id == appState.selectedAgent?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let agent = appState.selectedAgent {
                    Text(agent.emoji ?? "🤖")
                        .font(.title3)
                } else {
                    Image(systemName: "cpu")
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }
}
