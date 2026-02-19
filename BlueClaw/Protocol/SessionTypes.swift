import Foundation

nonisolated struct Session: Identifiable, Sendable {
    let id: String
    let key: String
    let agentId: String?
    let label: String?
    let model: String?
    let thinkingLevel: String?

    init(from dict: [String: Any]) {
        let sessionId = dict["sessionId"] as? String ?? dict["id"] as? String ?? UUID().uuidString
        id = sessionId
        key = dict["key"] as? String ?? dict["sessionKey"] as? String ?? sessionId
        agentId = dict["agentId"] as? String
        label = dict["label"] as? String
        model = dict["model"] as? String
        thinkingLevel = dict["thinkingLevel"] as? String
    }

    var displayName: String {
        label ?? key
    }
}
