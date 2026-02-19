import Foundation
import UIKit

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
    var pendingImage: UIImage?
    var sensitiveWarning: [SensitiveMatch]?

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

    func attachImage(_ image: UIImage) {
        pendingImage = image
    }

    func clearAttachment() {
        pendingImage = nil
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || pendingImage != nil, !isStreaming else { return }

        // Scan for sensitive content before sending
        let matches = ContentScanner.scan(text)
        if !matches.isEmpty {
            sensitiveWarning = matches
            return
        }

        await performSend()
    }

    private func performSend() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil, !isStreaming else { return }

        // Build attachments from pending image
        var attachments: [ChatSendAttachment]?
        var thumbnailData: Data?
        if let image {
            let (compressed, mimeType) = ImageCompressor.compress(image)
            thumbnailData = compressed
            attachments = [ChatSendAttachment(type: "image", mimeType: mimeType, content: compressed.base64EncodedString())]
        }

        let displayText = text.isEmpty ? "\u{1F4F7} Image" : text
        let userMessage = ChatMessage(role: .user, content: displayText, imageData: thumbnailData)
        messages.append(userMessage)
        inputText = ""
        pendingImage = nil
        isStreaming = true
        streamingContent = ""
        error = nil

        do {
            let message = text.isEmpty ? "Describe this image." : text
            try await client.sendMessage(sessionKey: sessionKey, message: message, attachments: attachments)
        } catch {
            isStreaming = false
            self.error = error.localizedDescription
        }
    }

    // MARK: - Sensitive Content

    func confirmSend() async {
        sensitiveWarning = nil
        await performSend()
    }

    func cancelSend() {
        sensitiveWarning = nil
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
