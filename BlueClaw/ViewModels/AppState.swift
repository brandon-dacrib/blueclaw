import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "priceconsulting.BlueClaw", category: "AppState")

@Observable
final class AppState {
    // Connection
    var connectionStatus: ConnectionStatus = .disconnected
    var lastConnectionError: BlueClawError?
    var hostname: String = ""
    var sshHost: String = ""
    var sshUser: String = ""

    // Data
    var agents: [Agent] = []
    var selectedAgent: Agent?
    var sessions: [Session] = []
    var activeSessionKey: String?

    // Health
    var isHealthy = false

    // Usage
    var usageData: UsageData?
    var isLoadingUsage = false

    // Reconnection
    private(set) var isReconnecting = false

    // Config
    var configSessionMainKey: String?

    // Chat view models keyed by session key
    var chatViewModels: [String: ChatViewModel] = [:]

    // Voice
    private var _voiceViewModel: VoiceViewModel?

    var isVoiceActive: Bool {
        guard let vm = _voiceViewModel else { return false }
        return vm.voiceService.isRecording || vm.voiceService.isSpeaking || vm.isWaiting
    }

    // Internal
    let client = GatewayClient()
    let tunnel = SSHTunnelService()
    private var eventTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    // Reconnection internals
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0

    // Health monitor internals
    private var healthCheckTask: Task<Void, Never>?
    private var consecutiveHealthFailures = 0
    private var usageRefreshTask: Task<Void, Never>?

    // Saved connection params for reconnection
    private var lastToken: String = ""

    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)

        static func == (lhs: ConnectionStatus, rhs: ConnectionStatus) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected): true
            case (.connecting, .connecting): true
            case (.connected, .connected): true
            case (.error(let a), .error(let b)): a == b
            default: false
            }
        }
    }

    // MARK: - SSH Tunnel + WebSocket Connection

    func connectViaSSH(sshHost: String, sshUser: String, sshPort: Int = 22, token: String) async {
        // Tear down any existing connection first to avoid stale listeners
        stopReconnectLoop()
        stopHealthCheckLoop()
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        await tunnel.disconnect()

        self.sshHost = sshHost
        self.sshUser = sshUser
        connectionStatus = .connecting
        lastConnectionError = nil
        lastToken = token

        do {
            // 1. Get SSH key
            log.info("Step 1: Retrieving SSH key...")
            guard let privateKey = SSHKeyManager.retrievePrivateKey() else {
                throw BlueClawError.sshError("No SSH key found. Generate one first.")
            }
            log.info("Step 1: SSH key retrieved")

            // 2. Establish SSH tunnel
            log.info("Step 2: Establishing SSH tunnel to \(sshHost, privacy: .public):\(sshPort)...")
            let localPort = try await tunnel.connect(
                host: sshHost,
                port: sshPort,
                username: sshUser,
                privateKey: privateKey
            )
            log.info("Step 2: SSH tunnel established, local port \(localPort)")

            // 3. Connect WebSocket through the tunnel
            let wsURL = "ws://127.0.0.1:\(localPort)"
            self.hostname = wsURL
            let displayName = ConnectParams.resolveDisplayName()
            log.info("Step 3: Connecting WebSocket to \(wsURL, privacy: .public)...")
            try await client.connect(hostname: wsURL, token: token, displayName: displayName)
            log.info("Step 3: WebSocket connected")

            connectionStatus = .connected
            isHealthy = true

            // Save credentials
            UserDefaults.standard.set(sshHost, forKey: "blueclaw.sshHost")
            UserDefaults.standard.set(sshUser, forKey: "blueclaw.sshUser")
            KeychainHelper.save(token: token, for: sshHost)

            // Load initial data
            await loadAgents()
            await loadSessions()
            await loadConfig()
            startEventListener()
            startHealthCheckLoop()
        } catch let error as BlueClawError {
            lastConnectionError = error
            connectionStatus = .error(error.shortDescription)
            isHealthy = false
        } catch {
            let wrapped = BlueClawError.sshError(error.localizedDescription)
            lastConnectionError = wrapped
            connectionStatus = .error(wrapped.shortDescription)
            isHealthy = false
        }
    }

    // MARK: - Direct Connection (fallback)

    func connect(hostname: String, token: String) async {
        // Tear down any existing connection first to avoid stale listeners
        stopReconnectLoop()
        stopHealthCheckLoop()
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        await tunnel.disconnect()

        self.hostname = hostname
        connectionStatus = .connecting
        lastConnectionError = nil
        lastToken = token

        do {
            let displayName = ConnectParams.resolveDisplayName()
            try await client.connect(hostname: hostname, token: token, displayName: displayName)
            connectionStatus = .connected
            isHealthy = true

            // Save credentials
            UserDefaults.standard.set(hostname, forKey: "blueclaw.hostname")
            KeychainHelper.save(token: token, for: hostname)

            // Load initial data
            await loadAgents()
            await loadSessions()
            await loadConfig()
            startEventListener()
            startHealthCheckLoop()
        } catch let error as BlueClawError {
            lastConnectionError = error
            connectionStatus = .error(error.shortDescription)
            isHealthy = false
        } catch {
            let wrapped = BlueClawError.connectionFailed(error.localizedDescription)
            lastConnectionError = wrapped
            connectionStatus = .error(error.localizedDescription)
            isHealthy = false
        }
    }

    func disconnect() async {
        stopReconnectLoop()
        stopHealthCheckLoop()
        stopUsageRefresh()
        eventTask?.cancel()
        eventTask = nil
        healthTask?.cancel()
        healthTask = nil
        await client.disconnect()
        await tunnel.disconnect()
        connectionStatus = .disconnected
        isHealthy = false
        agents = []
        sessions = []
        selectedAgent = nil
        activeSessionKey = nil
        chatViewModels = [:]
        _voiceViewModel?.stop()
        _voiceViewModel = nil
        usageData = nil
    }

    // MARK: - Silent Reconnect (preserves app state)

    func silentReconnect() async {
        // Only reconnect the transport layer — don't clear chatViewModels, sessions, agents, etc.
        log.info("Silent reconnect: re-establishing transport...")

        stopReconnectLoop()
        stopHealthCheckLoop()
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        await tunnel.disconnect()

        connectionStatus = .connecting

        do {
            let displayName = ConnectParams.resolveDisplayName()

            if !sshHost.isEmpty && !sshUser.isEmpty {
                let token = lastToken.isEmpty
                    ? (KeychainHelper.retrieve(for: sshHost) ?? "")
                    : lastToken

                guard let privateKey = SSHKeyManager.retrievePrivateKey() else {
                    throw BlueClawError.sshError("No SSH key found")
                }

                let localPort = try await tunnel.connect(
                    host: sshHost,
                    port: 22,
                    username: sshUser,
                    privateKey: privateKey
                )
                let wsURL = "ws://127.0.0.1:\(localPort)"
                self.hostname = wsURL
                try await client.connect(hostname: wsURL, token: token, displayName: displayName)
            } else {
                let token = lastToken.isEmpty
                    ? (KeychainHelper.retrieve(for: hostname) ?? "")
                    : lastToken
                try await client.connect(hostname: hostname, token: token, displayName: displayName)
            }

            log.info("Silent reconnect succeeded")
            connectionStatus = .connected
            isHealthy = true
            startEventListener()
            startHealthCheckLoop()

            // Refresh sessions/agents in background without blocking
            await loadSessions()
            await loadAgents()
        } catch {
            log.error("Silent reconnect failed: \(String(describing: error), privacy: .public)")
            // Fall back to reconnect loop
            startReconnectLoop()
        }
    }

    // MARK: - Reconnection

    func startReconnectLoop() {
        guard reconnectTask == nil else { return }
        isReconnecting = true
        stopHealthCheckLoop()

        reconnectTask = Task {
            while !Task.isCancelled {
                reconnectAttempt += 1
                let attempt = reconnectAttempt
                log.info("Reconnect attempt \(attempt)...")

                connectionStatus = .connecting

                do {
                    // Clean up existing connection state before reconnecting
                    await client.disconnect()
                    await tunnel.disconnect()

                    // Resolve display name on MainActor before entering actor calls
                    let displayName = ConnectParams.resolveDisplayName()

                    // Attempt reconnect using saved credentials
                    if !sshHost.isEmpty && !sshUser.isEmpty {
                        // SSH tunnel reconnect
                        let token = lastToken.isEmpty
                            ? (KeychainHelper.retrieve(for: sshHost) ?? "")
                            : lastToken

                        guard let privateKey = SSHKeyManager.retrievePrivateKey() else {
                            throw BlueClawError.sshError("No SSH key found")
                        }

                        let localPort = try await tunnel.connect(
                            host: sshHost,
                            port: 22,
                            username: sshUser,
                            privateKey: privateKey
                        )
                        let wsURL = "ws://127.0.0.1:\(localPort)"
                        self.hostname = wsURL
                        try await client.connect(hostname: wsURL, token: token, displayName: displayName)
                    } else {
                        // Direct reconnect
                        let token = lastToken.isEmpty
                            ? (KeychainHelper.retrieve(for: hostname) ?? "")
                            : lastToken

                        try await client.connect(hostname: hostname, token: token, displayName: displayName)
                    }

                    // Success
                    log.info("Reconnect succeeded on attempt \(attempt)")
                    reconnectAttempt = 0
                    isReconnecting = false
                    connectionStatus = .connected
                    isHealthy = true

                    // Reload data after reconnect
                    await loadAgents()
                    await loadSessions()
                    await loadConfig()
                    startEventListener()
                    startHealthCheckLoop()
                    reconnectTask = nil
                    return
                } catch {
                    let errorDesc = String(describing: error).lowercased()
                    if errorDesc.contains("auth")
                        || errorDesc.contains("unauthorized")
                        || errorDesc.contains("pairing") {
                        log.error("Reconnect aborted — auth/pairing error: \(String(describing: error), privacy: .public)")
                        isReconnecting = false
                        connectionStatus = .error("Authentication failed")
                        isHealthy = false
                        reconnectTask = nil
                        return
                    }

                    let delay = min(8.0, 0.5 * pow(1.7, Double(reconnectAttempt)))
                    log.info("Reconnect attempt \(attempt) failed, retrying in \(delay, format: .fixed(precision: 1))s")
                    connectionStatus = .error("Reconnecting...")

                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        // Task cancelled
                        break
                    }
                }
            }

            isReconnecting = false
            reconnectTask = nil
        }
    }

    func stopReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        isReconnecting = false
    }

    // MARK: - Health Check Loop

    private func startHealthCheckLoop() {
        stopHealthCheckLoop()
        consecutiveHealthFailures = 0

        healthCheckTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }

                do {
                    let healthy = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            try await self.client.healthCheck()
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(5))
                            throw BlueClawError.timeout
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }

                    if healthy {
                        consecutiveHealthFailures = 0
                        isHealthy = true
                    } else {
                        consecutiveHealthFailures += 1
                    }
                } catch {
                    consecutiveHealthFailures += 1
                    log.warning("Health check failed (\(self.consecutiveHealthFailures)/3): \(String(describing: error), privacy: .public)")
                }

                if consecutiveHealthFailures >= 3 {
                    log.error("Health check failed 3 consecutive times, triggering reconnect")
                    isHealthy = false
                    startReconnectLoop()
                    break
                }
            }
        }
    }

    private func stopHealthCheckLoop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        consecutiveHealthFailures = 0
    }

    // MARK: - Data Loading

    func loadAgents() async {
        do {
            log.info("Loading agents...")
            agents = try await client.listAgents()
            log.info("Loaded \(self.agents.count) agents: \(self.agents.map { $0.displayName }, privacy: .public)")
            if selectedAgent == nil, let first = agents.first {
                selectedAgent = first
                log.info("Auto-selected agent: \(first.displayName, privacy: .public)")
            }
        } catch {
            log.error("Failed to load agents: \(String(describing: error), privacy: .public)")
        }
    }

    func loadSessions() async {
        do {
            log.info("Loading sessions...")
            sessions = try await client.listSessions()
            log.info("Loaded \(self.sessions.count) sessions")
        } catch {
            log.error("Failed to load sessions: \(String(describing: error), privacy: .public)")
        }
    }

    func loadConfig() async {
        do {
            log.info("Loading config...")
            let config = try await client.getConfig()
            if let mainKey = config["sessionMainKey"] as? String {
                configSessionMainKey = mainKey
                log.info("Config sessionMainKey: \(mainKey, privacy: .public)")
            }
        } catch {
            log.error("Failed to load config: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Voice

    @MainActor
    func voiceViewModel() -> VoiceViewModel {
        if let existing = _voiceViewModel {
            return existing
        }
        let vm = VoiceViewModel(client: client, sessionKeyProvider: { [weak self] in
            self?.activeSessionKey
        })
        _voiceViewModel = vm
        return vm
    }

    // MARK: - Usage

    func loadUsage() async {
        isLoadingUsage = true
        do {
            usageData = try await client.fetchUsage()
        } catch {
            log.error("Failed to load usage: \(String(describing: error), privacy: .public)")
        }
        isLoadingUsage = false
    }

    func startUsageRefresh() {
        stopUsageRefresh()
        usageRefreshTask = Task {
            while !Task.isCancelled {
                await loadUsage()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    break
                }
            }
        }
    }

    func stopUsageRefresh() {
        usageRefreshTask?.cancel()
        usageRefreshTask = nil
    }

    // MARK: - Session Management

    func selectSession(key: String) {
        activeSessionKey = key
    }

    func chatViewModel(for sessionKey: String) -> ChatViewModel {
        if let existing = chatViewModels[sessionKey] {
            return existing
        }
        let vm = ChatViewModel(sessionKey: sessionKey, client: client)
        chatViewModels[sessionKey] = vm
        return vm
    }

    func resumeOrStartChat() {
        guard let agent = selectedAgent else { return }
        let prefix = "agent:\(agent.id):"
        // Find the most recent session for this agent
        if let existing = sessions.first(where: { $0.key.hasPrefix(prefix) }) {
            activeSessionKey = existing.key
            return
        }
        startNewChat()
    }

    func startNewChat() {
        guard let agent = selectedAgent else { return }
        let deviceName = UIDevice.current.name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let suffix = "\(deviceName)-\(timestamp)"
        let key = agent.sessionKey(suffix: suffix)
        activeSessionKey = key
    }

    // MARK: - Event Listener

    func startEventListener() {
        eventTask?.cancel()
        eventTask = Task {
            let events = await client.events
            for await frame in events {
                guard !Task.isCancelled else { break }
                await handleEvent(frame)
            }
            // Event stream ended — if we didn't initiate disconnect, reconnect
            if !Task.isCancelled && connectionStatus == .connected {
                log.info("Event stream ended unexpectedly, triggering reconnect")
                connectionStatus = .disconnected
                isHealthy = false
                startReconnectLoop()
            }
        }
    }

    private func handleEvent(_ frame: RawFrame) async {
        guard frame.type == "event" else { return }

        switch frame.event {
        case "chat":
            guard let dict = frame.payloadDictionary() else { return }
            let chatEvent = ChatEventPayload(from: dict)
            let eventKey = chatEvent.sessionKey

            // Always route to the matching chat VM
            if let chatVM = chatViewModels[eventKey] {
                chatVM.handleChatEvent(chatEvent)
            }

            // Also route to voice VM if it's waiting for a response on this session
            if let voiceVM = _voiceViewModel, voiceVM.isWaiting, eventKey == activeSessionKey {
                voiceVM.handleChatEvent(chatEvent)
            }

        case "health":
            isHealthy = true

        case "shutdown":
            connectionStatus = .disconnected
            isHealthy = false
            startReconnectLoop()

        default:
            break
        }
    }

    // MARK: - Saved Credentials

    var savedSSHHost: String? {
        UserDefaults.standard.string(forKey: "blueclaw.sshHost")
    }

    var savedSSHUser: String? {
        UserDefaults.standard.string(forKey: "blueclaw.sshUser")
    }

    var savedHostname: String? {
        UserDefaults.standard.string(forKey: "blueclaw.hostname")
    }

    var savedConnectionMode: ConnectionViewModel.ConnectionMode? {
        guard let raw = UserDefaults.standard.string(forKey: "blueclaw.connectionMode") else {
            return nil
        }
        return ConnectionViewModel.ConnectionMode(rawValue: raw)
    }

    func saveConnectionMode(_ mode: ConnectionViewModel.ConnectionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "blueclaw.connectionMode")
    }

    func savedToken(for hostname: String) -> String? {
        KeychainHelper.retrieve(for: hostname)
    }
}
