import Foundation

nonisolated enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

nonisolated struct ChatMessage: Identifiable, Sendable {
    let id: String
    let role: MessageRole
    var content: String
    let timestamp: Date

    init(id: String = UUID().uuidString, role: MessageRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

nonisolated struct ChatEventPayload: Sendable {
    let runId: String
    let sessionKey: String
    let seq: Int
    let state: ChatStreamState
    let contentDelta: String?
    let fullContent: String?

    init(from dict: [String: Any]) {
        runId = dict["runId"] as? String ?? ""
        sessionKey = dict["sessionKey"] as? String ?? ""
        seq = dict["seq"] as? Int ?? 0

        let stateStr = dict["state"] as? String ?? ""
        state = ChatStreamState(rawValue: stateStr) ?? .error

        if let message = dict["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                if state == .delta {
                    contentDelta = content
                    fullContent = nil
                } else {
                    contentDelta = nil
                    fullContent = content
                }
            } else if let parts = message["content"] as? [[String: Any]] {
                let text = parts.compactMap { part -> String? in
                    if part["type"] as? String == "text" {
                        return part["text"] as? String
                    }
                    return nil
                }.joined()
                if state == .delta {
                    contentDelta = text
                    fullContent = nil
                } else {
                    contentDelta = nil
                    fullContent = text
                }
            } else {
                contentDelta = nil
                fullContent = nil
            }
        } else {
            contentDelta = nil
            fullContent = nil
        }
    }
}

nonisolated enum ChatStreamState: String, Sendable {
    case delta
    case final_ = "final"
    case aborted
    case error
}

nonisolated struct ChatSendParams: Codable, Sendable {
    let sessionKey: String
    let message: String
    let idempotencyKey: String
    let thinking: String?
    let timeoutMs: Int?
}

nonisolated struct ChatHistoryParams: Codable, Sendable {
    let sessionKey: String
}

nonisolated struct ChatAbortParams: Codable, Sendable {
    let sessionKey: String
    let runId: String
}

nonisolated struct HistoryEntry: Sendable {
    let role: MessageRole
    let content: String
    let timestamp: Date?

    init(from dict: [String: Any]) {
        let roleStr = dict["role"] as? String ?? "assistant"
        role = MessageRole(rawValue: roleStr) ?? .assistant

        if let content = dict["content"] as? String {
            self.content = content
        } else if let parts = dict["content"] as? [[String: Any]] {
            self.content = parts.compactMap { part -> String? in
                if part["type"] as? String == "text" {
                    return part["text"] as? String
                }
                return nil
            }.joined()
        } else {
            self.content = ""
        }

        if let ts = dict["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: ts)
        } else {
            timestamp = nil
        }
    }
}
