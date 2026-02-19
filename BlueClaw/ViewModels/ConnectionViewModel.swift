import Foundation

@Observable
final class ConnectionViewModel {
    // Connection mode
    var connectionMode: ConnectionMode = .sshWSS {
        didSet { validateHost() }
    }

    // Host field — used as SSH host in SSH modes, gateway host in direct modes
    var host: String = "" {
        didSet { validateHost() }
    }
    var port: String = ""
    var sshUser: String = ""
    var token: String = ""

    // Connection state
    var isConnecting = false
    var errorMessage: String?
    var errorDetail: String?
    var hasSavedCredentials = false
    var requiresBiometric = false
    var showInsecureWarning = false

    // SSH key state
    var hasSSHKey = false
    var publicKeyString: String?
    var publicKeyCopied = false

    // Validation
    var hostValidation: FieldValidation = .empty

    // MARK: - Types

    enum ConnectionMode: String, CaseIterable, Identifiable {
        case sshWSS = "ssh+wss"
        case wss = "wss"
        case ws = "ws"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sshWSS: "ssh+wss://"
            case .wss: "wss://"
            case .ws: "ws://"
            }
        }

        var shortLabel: String {
            switch self {
            case .sshWSS: "SSH + WSS"
            case .wss: "WSS"
            case .ws: "WS"
            }
        }

        var description: String {
            switch self {
            case .sshWSS: "SSH tunnel with encrypted WebSocket"
            case .wss: "Encrypted WebSocket (TLS)"
            case .ws: "Unencrypted WebSocket"
            }
        }

        var securityLevel: SecurityLevel {
            switch self {
            case .sshWSS: .high
            case .wss: .medium
            case .ws: .low
            }
        }

        var needsSSH: Bool {
            self == .sshWSS
        }

        var needsPort: Bool {
            switch self {
            case .sshWSS: false  // SSH port is always 22 (or configurable via sshPort)
            case .wss, .ws: true
            }
        }

        enum SecurityLevel {
            case high, medium, low
        }
    }

    enum FieldValidation: Equatable {
        case empty
        case valid
        case invalid(String)
    }

    // MARK: - Validation

    private var isParsing = false

    private func validateHost() {
        guard !isParsing else { return }
        isParsing = true
        defer { isParsing = false }

        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            hostValidation = .empty
            return
        }

        // Strip scheme if user pasted a URL
        var h = trimmed
        if let schemeRange = h.range(of: "://") {
            h = String(h[schemeRange.upperBound...])
        }
        // Strip path and trailing slash
        if let slashIdx = h.firstIndex(of: "/") {
            h = String(h[h.startIndex..<slashIdx])
        }
        // Strip port
        if let colonIdx = h.lastIndex(of: ":") {
            let portPart = String(h[h.index(after: colonIdx)...])
            if Int(portPart) != nil {
                h = String(h[h.startIndex..<colonIdx])
            }
        }

        // Auto-clean the field if it had a scheme/path/port
        if h != trimmed {
            host = h
            // Don't re-validate, we already have the clean value
        }

        if h.isEmpty {
            hostValidation = .invalid("Host is required")
            return
        }

        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-[]"))
        if h.unicodeScalars.contains(where: { !allowedChars.contains($0) }) {
            hostValidation = .invalid("Invalid characters in hostname")
            return
        }

        if h.hasPrefix(".") || h.hasSuffix(".") || h.contains("..") {
            hostValidation = .invalid("Invalid hostname format")
            return
        }

        hostValidation = .valid
    }

    // MARK: - Computed Properties

    var effectiveHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var h = trimmed
        if let schemeRange = h.range(of: "://") {
            h = String(h[schemeRange.upperBound...])
        }
        if let slashIdx = h.firstIndex(of: "/") {
            h = String(h[h.startIndex..<slashIdx])
        }
        if let colonIdx = h.lastIndex(of: ":") {
            let portPart = String(h[h.index(after: colonIdx)...])
            if Int(portPart) != nil {
                h = String(h[h.startIndex..<colonIdx])
            }
        }
        return h
    }

    var effectivePort: Int {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        if let p = Int(trimmed), p >= 1, p <= 65535 {
            return p
        }
        switch connectionMode {
        case .sshWSS: return 22
        case .wss: return 443
        case .ws: return 18789
        }
    }

    var effectiveGatewayPort: Int {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        if let p = Int(trimmed), p >= 1, p <= 65535 {
            return p
        }
        return 18789
    }

    var connectionPreview: String? {
        let h = effectiveHost
        guard !h.isEmpty else { return nil }

        switch connectionMode {
        case .sshWSS:
            let user = sshUser.trimmingCharacters(in: .whitespaces)
            let sshPort = effectivePort
            let sshPart = user.isEmpty ? h : "\(user)@\(h)"
            return "ssh \(sshPart):\(sshPort) \u{2192} ws://localhost:18789"

        case .wss:
            let p = effectiveGatewayPort
            return "wss://\(h):\(p)"

        case .ws:
            let p = effectiveGatewayPort
            return "ws://\(h):\(p)"
        }
    }

    var canConnect: Bool {
        let h = effectiveHost
        let hostOk: Bool = switch hostValidation {
        case .invalid: false
        default: true
        }

        let baseOk = !h.isEmpty &&
            !token.trimmingCharacters(in: .whitespaces).isEmpty &&
            hostOk &&
            !isConnecting

        switch connectionMode {
        case .sshWSS:
            return baseOk &&
                !sshUser.trimmingCharacters(in: .whitespaces).isEmpty &&
                hasSSHKey
        case .wss, .ws:
            return baseOk
        }
    }

    // MARK: - SSH Key Management

    func loadSSHKeyState() {
        hasSSHKey = SSHKeyManager.hasKey
        publicKeyString = SSHKeyManager.publicKeyOpenSSH()
    }

    func generateSSHKey() {
        SSHKeyManager.generateAndStore()
        loadSSHKeyState()
    }

    // MARK: - Saved Credentials

    func loadSavedCredentials(from appState: AppState) {
        loadSSHKeyState()

        // Load saved connection mode
        if let savedMode = appState.savedConnectionMode {
            connectionMode = savedMode
        }

        // Load host based on mode
        let savedHost: String?
        switch connectionMode {
        case .sshWSS:
            savedHost = appState.savedSSHHost
            sshUser = appState.savedSSHUser ?? ""
        case .wss, .ws:
            savedHost = appState.savedHostname
        }

        if let savedHost, !savedHost.isEmpty {
            host = savedHost
            if appState.savedToken(for: savedHost) != nil {
                hasSavedCredentials = true
                if BiometricAuth.isAvailable {
                    requiresBiometric = true
                } else {
                    token = appState.savedToken(for: savedHost) ?? ""
                }
            }
        }
    }

    func authenticateAndConnect(appState: AppState) async {
        guard hasSavedCredentials else { return }

        if BiometricAuth.isAvailable {
            let authenticated = await BiometricAuth.authenticate(
                reason: "Authenticate to connect to \(effectiveHost)"
            )
            guard authenticated else {
                errorMessage = "Authentication required to access saved credentials"
                return
            }
        }

        let savedHost: String
        switch connectionMode {
        case .sshWSS:
            savedHost = appState.savedSSHHost ?? host
        case .wss, .ws:
            savedHost = appState.savedHostname ?? host
        }

        if let savedToken = appState.savedToken(for: savedHost) {
            token = savedToken
            await connect(appState: appState)
        } else {
            errorMessage = "Saved token not found. Please enter manually."
            hasSavedCredentials = false
            requiresBiometric = false
        }
    }

    // MARK: - Connect

    func connect(appState: AppState) async {
        let h = effectiveHost
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !h.isEmpty, !trimmedToken.isEmpty else {
            errorMessage = "Please fill in all fields"
            errorDetail = nil
            return
        }

        guard hostValidation == .valid || hostValidation == .empty else {
            if case .invalid(let msg) = hostValidation {
                errorMessage = msg
            }
            errorDetail = nil
            return
        }

        isConnecting = true
        errorMessage = nil
        errorDetail = nil

        switch connectionMode {
        case .sshWSS:
            let user = sshUser.trimmingCharacters(in: .whitespaces)
            guard !user.isEmpty else {
                errorMessage = "SSH user is required"
                errorDetail = nil
                isConnecting = false
                return
            }
            guard hasSSHKey else {
                errorMessage = "Generate an SSH key first"
                errorDetail = nil
                isConnecting = false
                return
            }

            await appState.connectViaSSH(
                sshHost: h,
                sshUser: user,
                sshPort: effectivePort,
                token: trimmedToken
            )

        case .wss:
            let url = "wss://\(h):\(effectiveGatewayPort)"
            await appState.connect(hostname: url, token: trimmedToken)

        case .ws:
            let url = "ws://\(h):\(effectiveGatewayPort)"
            await appState.connect(hostname: url, token: trimmedToken)
        }

        // Save the connection mode
        appState.saveConnectionMode(connectionMode)

        if case .error(let msg) = appState.connectionStatus {
            errorMessage = msg
            errorDetail = appState.lastConnectionError?.technicalDetail
        }

        isConnecting = false
    }
}
