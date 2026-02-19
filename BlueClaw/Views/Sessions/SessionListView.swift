import SwiftUI

struct SessionListView: View {
    @Environment(AppState.self) private var appState
    var switchToChat: (() -> Void)?

    var body: some View {
        List {
            if appState.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "bubble.left")
                } description: {
                    Text("Start a new conversation from the Chat tab")
                }
            } else {
                ForEach(appState.sessions) { session in
                    SessionRowView(session: session)
                        .onTapGesture {
                            appState.selectSession(key: session.key)
                            switchToChat?()
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
        .refreshable {
            await appState.loadSessions()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appState.startNewChat()
                    switchToChat?()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(appState.selectedAgent == nil)
            }
        }
    }
}
