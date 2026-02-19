import Foundation

nonisolated enum GatewayMethod {
    static let connect = "connect"
    static let health = "health"
    static let agentsList = "agents.list"
    static let sessionsList = "sessions.list"
    static let sessionsResolve = "sessions.resolve"
    static let sessionsPatch = "sessions.patch"
    static let sessionsDelete = "sessions.delete"
    static let chatSend = "chat.send"
    static let chatHistory = "chat.history"
    static let chatAbort = "chat.abort"
    static let modelsList = "models.list"
    static let status = "status"
    static let configGet = "config.get"
}

nonisolated struct SessionResolveParams: Codable, Sendable {
    let key: String
}

nonisolated struct SessionsListParams: Codable, Sendable {
    let includeGlobal: Bool
    let includeUnknown: Bool
    let limit: Int
}
