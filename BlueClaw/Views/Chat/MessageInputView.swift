import SwiftUI

struct MessageInputView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(AppColors.surfaceBorder)

            HStack(alignment: .bottom, spacing: 10) {
                // Text input
                TextField("Message", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(isFocused ? AppColors.accent.opacity(0.5) : AppColors.inputBorder, lineWidth: 1)
                    )
                    .onSubmit {
                        Task { await viewModel.send() }
                    }

                // Send / Abort button
                if viewModel.isStreaming {
                    Button {
                        Task { await viewModel.abort() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(AppColors.accent)
                    }
                } else {
                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(canSend ? AppColors.accent : AppColors.textMuted)
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppColors.surface)
        }
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isStreaming
    }
}
