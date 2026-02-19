import Foundation
import os.log

private let log = Logger(subsystem: "priceconsulting.BlueClaw", category: "GatewayClient")

actor GatewayClient {
    let service = WebSocketService()

    var events: AsyncStream<RawFrame> {
        get async { await service.events }
    }

    var isConnected: Bool {
        get async {
            let state = await service.state
            return state == .connected
        }
    }

    func connect(hostname: String, token: String, displayName: String = "BlueClaw iOS") async throws {
        try await service.connect(hostname: hostname, token: token, displayName: displayName)
    }

    func disconnect() async {
        await service.disconnect()
    }

    // MARK: - Agents

    func listAgents() async throws -> [Agent] {
        let response = try await service.send(method: GatewayMethod.agentsList)
        log.info("agents.list response ok=\(response.ok ?? false) error=\(response.error?.message ?? "none", privacy: .public)")
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
        guard let payload = response.payloadDictionary() else {
            log.info("agents.list: no payload dictionary")
            return []
        }
        log.info("agents.list payload keys: \(Array(payload.keys), privacy: .public)")
        let agentsArray: [[String: Any]]
        if let agents = payload["agents"] as? [[String: Any]] {
            agentsArray = agents
        } else if let list = response.payload?.array as? [[String: Any]] {
            agentsArray = list
        } else {
            log.info("agents.list: could not find agents array in payload")
            return []
        }
        log.info("agents.list: found \(agentsArray.count) agents")
        return agentsArray.map { Agent(from: $0) }
    }

    // MARK: - Sessions

    func listSessions() async throws -> [Session] {
        let params = SessionsListParams(includeGlobal: true, includeUnknown: true, limit: 100)
        let response = try await service.send(method: GatewayMethod.sessionsList, params: params)
        log.info("sessions.list response ok=\(response.ok ?? false) error=\(response.error?.message ?? "none", privacy: .public)")
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
        guard let payload = response.payloadDictionary() else {
            log.info("sessions.list: no payload dictionary")
            return []
        }
        log.info("sessions.list payload keys: \(Array(payload.keys), privacy: .public)")
        let sessionsArray: [[String: Any]]
        if let sessions = payload["sessions"] as? [[String: Any]] {
            sessionsArray = sessions
        } else if let list = response.payload?.array as? [[String: Any]] {
            sessionsArray = list
        } else {
            log.info("sessions.list: could not find sessions array in payload")
            return []
        }
        log.info("sessions.list: found \(sessionsArray.count) sessions")
        return sessionsArray.map { Session(from: $0) }
    }

    func resolveSession(key: String) async throws -> Session {
        let params = SessionResolveParams(key: key)
        let response = try await service.send(method: GatewayMethod.sessionsResolve, params: params)
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
        guard let dict = response.payloadDictionary() else {
            throw BlueClawError.missingPayload
        }
        return Session(from: dict)
    }

    // MARK: - Chat

    func sendMessage(sessionKey: String, message: String, thinking: String? = "low", timeoutMs: Int? = 30000) async throws {
        let params = ChatSendParams(
            sessionKey: sessionKey,
            message: message,
            idempotencyKey: UUID().uuidString,
            thinking: thinking,
            timeoutMs: timeoutMs
        )
        let response = try await service.send(method: GatewayMethod.chatSend, params: params)
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
    }

    func fetchHistory(sessionKey: String) async throws -> [HistoryEntry] {
        let params = ChatHistoryParams(sessionKey: sessionKey)
        let response = try await service.send(method: GatewayMethod.chatHistory, params: params)
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
        guard let payload = response.payloadDictionary() else {
            return []
        }
        let messagesArray: [[String: Any]]
        if let messages = payload["messages"] as? [[String: Any]] {
            messagesArray = messages
        } else if let history = payload["history"] as? [[String: Any]] {
            messagesArray = history
        } else if let list = response.payload?.array as? [[String: Any]] {
            messagesArray = list
        } else {
            return []
        }
        return messagesArray.map { HistoryEntry(from: $0) }
    }

    func abortGeneration(sessionKey: String, runId: String) async throws {
        let params = ChatAbortParams(sessionKey: sessionKey, runId: runId)
        let response = try await service.send(method: GatewayMethod.chatAbort, params: params)
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
    }

    // MARK: - Config

    func getConfig() async throws -> [String: Any] {
        let response = try await service.send(method: GatewayMethod.configGet)
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
        return response.payloadDictionary() ?? [:]
    }

    // MARK: - Health

    func healthCheck() async throws -> Bool {
        let response = try await service.send(method: GatewayMethod.health)
        return response.ok == true
    }
}
