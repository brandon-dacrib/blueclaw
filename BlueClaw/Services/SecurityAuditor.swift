import Foundation

@MainActor
final class SecurityAuditor {
    private let client: GatewayClient
    private let hostname: String
    private let sshHost: String

    init(client: GatewayClient, hostname: String, sshHost: String) {
        self.client = client
        self.hostname = hostname
        self.sshHost = sshHost
    }

    func runAudit(progress: (Double) -> Void) async -> AuditReport {
        var findings: [AuditFinding] = []
        var gatewayVersion = "Unknown"

        progress(0.2)
        let (gatewayFinding, version) = await auditGateway()
        findings.append(gatewayFinding)
        gatewayVersion = version

        progress(0.4)
        findings.append(auditTransport())

        progress(0.6)
        findings.append(auditDataProtection())

        progress(0.8)
        findings.append(auditCredentials())

        progress(1.0)

        let report = AuditReport(findings: findings, gatewayVersion: gatewayVersion)
        Self.saveReport(report)
        return report
    }

    // MARK: - Gateway

    private func auditGateway() async -> (AuditFinding, String) {
        var version = "Unknown"

        if let ver = await client.serverVersion {
            version = ver
        } else if let ver = await client.fetchServerVersion() {
            version = ver
        }

        do {
            let healthy = try await client.healthCheck()
            if healthy {
                return (AuditFinding(
                    category: "Gateway",
                    title: "Gateway Responding",
                    description: "The gateway is reachable and healthy.",
                    severity: .pass,
                    recommendation: "No action needed."
                ), version)
            } else {
                return (AuditFinding(
                    category: "Gateway",
                    title: "Gateway Unhealthy",
                    description: "The gateway responded but reported an unhealthy status.",
                    severity: .high,
                    recommendation: "Check gateway logs and restart if needed."
                ), version)
            }
        } catch {
            return (AuditFinding(
                category: "Gateway",
                title: "Gateway Unreachable",
                description: "Could not reach the gateway: \(error.localizedDescription)",
                severity: .critical,
                recommendation: "Verify the gateway is running and your network connection is active."
            ), version)
        }
    }

    // MARK: - Transport Encryption

    private func auditTransport() -> AuditFinding {
        let url = hostname.lowercased()
        let hasSSHTunnel = !sshHost.isEmpty
        let isLocalhost = url.contains("127.0.0.1") || url.contains("localhost") || url.contains("[::1]")
        let isEncryptedScheme = url.hasPrefix("wss://") || url.hasPrefix("https://")

        // Check if the path to the gateway traverses Tailscale.
        // Must check both hostname AND sshHost — when SSH tunneling, the
        // .ts.net address is in sshHost while hostname is localhost.
        let tailscaleActive = Self.detectTailscale()
        let hostOnTailscale = url.contains(".ts.net") || Self.isTailscaleIP(url)
        let sshOnTailscale = hasSSHTunnel && (sshHost.lowercased().contains(".ts.net") || Self.isTailscaleIP(sshHost.lowercased()))
        let viaTailscale = tailscaleActive && (hostOnTailscale || sshOnTailscale)

        // Collect all encryption layers protecting the traffic
        var layers: [String] = []
        if isEncryptedScheme { layers.append("TLS") }
        if hasSSHTunnel { layers.append("SSH tunnel to \(sshHost)") }
        if viaTailscale { layers.append("Tailscale WireGuard") }

        if !layers.isEmpty {
            let desc: String
            switch layers.count {
            case 1: desc = "Traffic is encrypted via \(layers[0])."
            case 2: desc = "Traffic is encrypted via \(layers[0]) and \(layers[1])."
            default: desc = "Traffic is encrypted via \(layers.dropLast().joined(separator: ", ")), and \(layers.last!)."
            }
            return AuditFinding(
                category: "Transport",
                title: "Encrypted",
                description: desc,
                severity: .pass,
                recommendation: "No action needed."
            )
        }

        if isLocalhost {
            return AuditFinding(
                category: "Transport",
                title: "Local Only",
                description: "Using unencrypted WebSocket over localhost. Traffic stays on-device.",
                severity: .info,
                recommendation: "Acceptable if the gateway runs locally. For remote gateways, use wss:// or SSH tunneling."
            )
        }

        return AuditFinding(
            category: "Transport",
            title: "Not Encrypted",
            description: "Traffic to the gateway is unencrypted. Messages, tokens, and API keys are sent in plaintext.",
            severity: .critical,
            recommendation: "Switch to wss://, use SSH tunneling, or connect via Tailscale."
        )
    }

    // MARK: - Data Protection

    private func auditDataProtection() -> AuditFinding {
        if ContentScanner.isEnabled {
            return AuditFinding(
                category: "Data Protection",
                title: "Content Scanning Enabled",
                description: "Outgoing messages are scanned for API keys, secrets, and PII before sending.",
                severity: .pass,
                recommendation: "No action needed."
            )
        }
        return AuditFinding(
            category: "Data Protection",
            title: "Content Scanning Disabled",
            description: "Outgoing messages are not scanned for sensitive data.",
            severity: .low,
            recommendation: "Enable in Settings to scan for API keys and PII before sending."
        )
    }

    // MARK: - Credential Storage

    private func auditCredentials() -> AuditFinding {
        if UserDefaults.standard.string(forKey: "blueclaw.token") != nil {
            return AuditFinding(
                category: "Credentials",
                title: "Token in UserDefaults",
                description: "Authentication token is stored in UserDefaults, which is not encrypted at rest.",
                severity: .medium,
                recommendation: "Migrate to the iOS Keychain for hardware-backed encryption."
            )
        }
        return AuditFinding(
            category: "Credentials",
            title: "Token in Keychain",
            description: "Authentication token is stored in the iOS Keychain with hardware-backed encryption.",
            severity: .pass,
            recommendation: "No action needed."
        )
    }

    // MARK: - Tailscale Detection

    /// Detects whether Tailscale is active by checking for a utun interface
    /// with a Tailscale CGNAT IP (100.64.0.0/10).
    static func detectTailscale() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return false }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        while let addr = current {
            let name = String(cString: addr.pointee.ifa_name)
            if name.hasPrefix("utun"), let sa = addr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var sin = sockaddr_in()
                memcpy(&sin, sa, MemoryLayout<sockaddr_in>.size)
                let ip = sin.sin_addr.s_addr
                let byte0 = ip & 0xFF
                let byte1 = (ip >> 8) & 0xFF
                if byte0 == 100 && (byte1 & 0xC0) == 64 {
                    return true
                }
            }
            current = addr.pointee.ifa_next
        }
        return false
    }

    private static func isTailscaleIP(_ host: String) -> Bool {
        let pattern = #"100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}"#
        return host.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Latest Version Lookup

    nonisolated static func fetchLatestVersion() async -> String? {
        let tagsURL = URL(string: "https://api.github.com/repos/openclaw/openclaw/tags?per_page=30")!
        do {
            var request = URLRequest(url: tagsURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let tags = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            let stablePattern = try NSRegularExpression(pattern: #"^v\d+\.\d+\.\d+$"#)
            for tag in tags {
                guard let name = tag["name"] as? String else { continue }
                let range = NSRange(name.startIndex..., in: name)
                if stablePattern.firstMatch(in: name, range: range) != nil {
                    return name
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Compare calver version strings (vYYYY.M.D). Returns true if `running` >= `latest`.
    nonisolated static func isVersionCurrent(_ running: String, latest: String) -> Bool {
        let r = parseVersion(running)
        let l = parseVersion(latest)
        if r.major != l.major { return r.major > l.major }
        if r.minor != l.minor { return r.minor > l.minor }
        return r.patch >= l.patch
    }

    private nonisolated static func parseVersion(_ version: String) -> (major: Int, minor: Int, patch: Int) {
        var cleaned = version.trimmingCharacters(in: CharacterSet.letters.union(.whitespaces))
        if let dashIndex = cleaned.firstIndex(of: "-") {
            cleaned = String(cleaned[cleaned.startIndex..<dashIndex])
        }
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        return (
            major: parts.count > 0 ? parts[0] : 0,
            minor: parts.count > 1 ? parts[1] : 0,
            patch: parts.count > 2 ? parts[2] : 0
        )
    }

    // MARK: - Persistence

    private static let reportKey = "blueclaw_audit_report"

    static func saveReport(_ report: AuditReport) {
        if let data = try? JSONEncoder().encode(report) {
            UserDefaults.standard.set(data, forKey: reportKey)
        }
    }

    static func loadLastReport() -> AuditReport? {
        guard let data = UserDefaults.standard.data(forKey: reportKey) else { return nil }
        return try? JSONDecoder().decode(AuditReport.self, from: data)
    }
}
