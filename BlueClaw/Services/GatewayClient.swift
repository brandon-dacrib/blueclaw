import Foundation
import os.log

private nonisolated let log = Logger(subsystem: "priceconsulting.BlueClaw", category: "GatewayClient")

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

    var serverVersion: String? {
        get async { await service.serverVersion }
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

    func sendMessage(sessionKey: String, message: String, thinking: String? = "low", timeoutMs: Int? = 30000, attachments: [ChatSendAttachment]? = nil) async throws {
        let params = ChatSendParams(
            sessionKey: sessionKey,
            message: message,
            idempotencyKey: UUID().uuidString,
            thinking: thinking,
            timeoutMs: timeoutMs,
            attachments: attachments
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

    // MARK: - Usage

    func fetchUsage() async throws -> UsageData {
        let response = try await service.send(method: GatewayMethod.usageCost)
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
        guard let payload = response.payloadDictionary() else {
            throw BlueClawError.missingPayload
        }
        return UsageData(from: payload)
    }

    // MARK: - Health

    func healthCheck() async throws -> Bool {
        let response = try await service.send(method: GatewayMethod.health)
        return response.ok == true
    }

    // MARK: - Status / Version

    func fetchStatus() async throws -> [String: Any] {
        let response = try await service.send(method: GatewayMethod.status)
        guard response.ok == true else {
            throw BlueClawError.serverError(code: response.error?.code, message: response.error?.message)
        }
        return response.payloadDictionary() ?? [:]
    }

    /// Attempts to resolve the gateway server version from available endpoints.
    /// Tries status, then config, then health — returns the first version found.
    func fetchServerVersion() async -> String? {
        // Try status endpoint — may have top-level "version" or nested "server.version"
        if let status = try? await fetchStatus() {
            if let v = status["version"] as? String { return v }
            if let server = status["server"] as? [String: Any],
               let v = server["version"] as? String { return v }
        }

        // Try config endpoint
        if let config = try? await getConfig() {
            if let v = config["version"] as? String { return v }
            if let v = config["gatewayVersion"] as? String { return v }
            if let server = config["server"] as? [String: Any],
               let v = server["version"] as? String { return v }
        }

        // Try health endpoint payload
        if let response = try? await service.send(method: GatewayMethod.health),
           let payload = response.payloadDictionary() {
            if let v = payload["version"] as? String { return v }
            if let server = payload["server"] as? [String: Any],
               let v = server["version"] as? String { return v }
        }

        return nil
    }
}
