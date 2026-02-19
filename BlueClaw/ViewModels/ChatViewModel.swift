import Foundation

@Observable
final class ChatViewModel {
    let sessionKey: String
    private let client: GatewayClient

    var messages: [ChatMessage] = []
    var streamingContent: String = ""
    var isStreaming = false
    var currentRunId: String?
    var inputText: String = ""
    var isLoadingHistory = false
    var error: String?

    init(sessionKey: String, client: GatewayClient) {
        self.sessionKey = sessionKey
        self.client = client
    }

    // MARK: - History

    func loadHistory() async {
        guard messages.isEmpty else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let entries = try await client.fetchHistory(sessionKey: sessionKey)
            messages = entries.map { entry in
                ChatMessage(
                    role: entry.role,
                    content: entry.content,
                    timestamp: entry.timestamp ?? Date()
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Send

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        inputText = ""
        isStreaming = true
        streamingContent = ""
        error = nil

        do {
            try await client.sendMessage(sessionKey: sessionKey, message: text)
        } catch {
            isStreaming = false
            self.error = error.localizedDescription
        }
    }

    // MARK: - Abort

    func abort() async {
        guard let runId = currentRunId else { return }
        do {
            try await client.abortGeneration(sessionKey: sessionKey, runId: runId)
        } catch {
            // Ignore abort errors
        }
    }

    // MARK: - Event Handling

    func handleChatEvent(_ event: ChatEventPayload) {
        switch event.state {
        case .delta:
            isStreaming = true
            currentRunId = event.runId
            if let delta = event.contentDelta {
                streamingContent += delta
            }

        case .final_:
            let finalContent = event.fullContent ?? streamingContent
            if !finalContent.isEmpty {
                let assistantMessage = ChatMessage(
                    role: .assistant,
                    content: finalContent
                )
                messages.append(assistantMessage)
            }
            isStreaming = false
            streamingContent = ""
            currentRunId = nil

        case .aborted:
            if !streamingContent.isEmpty {
                let partialMessage = ChatMessage(
                    role: .assistant,
                    content: streamingContent + " [aborted]"
                )
                messages.append(partialMessage)
            }
            isStreaming = false
            streamingContent = ""
            currentRunId = nil

        case .error:
            isStreaming = false
            streamingContent = ""
            currentRunId = nil
            error = "Generation failed"
        }
    }
}
