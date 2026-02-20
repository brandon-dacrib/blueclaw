import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Bindable var viewModel: ChatViewModel

    /// Resolve the agent for this chat from the session key (format: `agent:<id>:<suffix>`)
    private var agent: Agent? {
        let parts = viewModel.sessionKey.split(separator: ":")
        guard parts.count >= 2, parts[0] == "agent" else { return nil }
        let agentId = String(parts[1])
        return appState.agents.first { $0.id == agentId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(
                                message: message,
                                agentEmoji: agent?.emoji,
                                agentName: agent?.name
                            )
                            .id(message.id)
                        }

                        // Streaming message
                        if viewModel.isStreaming && !viewModel.streamingContent.isEmpty {
                            MessageBubbleView(
                                message: ChatMessage(
                                    id: "streaming",
                                    role: .assistant,
                                    content: viewModel.streamingContent
                                ),
                                isStreaming: true,
                                agentEmoji: agent?.emoji,
                                agentName: agent?.name
                            )
                            .id("streaming")
                        }

                        // Invisible anchor for scrolling
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.count) {
                    // Slight delay lets the layout settle after the streaming
                    // bubble is removed and the final message is inserted
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.streamingContent) {
                    // Only scroll while content is growing, not when it resets to ""
                    if !viewModel.streamingContent.isEmpty {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            // Error banner
            if let error = viewModel.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button {
                        viewModel.error = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(AppColors.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(AppColors.accent.opacity(0.1))
            }

            // Input bar
            MessageInputView(viewModel: viewModel)
        }
        .background(AppColors.background)
        .task {
            await viewModel.loadHistory()
        }
    }
}
