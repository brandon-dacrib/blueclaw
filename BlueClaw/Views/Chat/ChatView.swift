import SwiftUI

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(message: message)
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
                                isStreaming: true
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
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.streamingContent) {
                    proxy.scrollTo("bottom", anchor: .bottom)
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
