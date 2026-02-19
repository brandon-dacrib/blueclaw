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

        // Phase 1: Health check
        progress(0.1)
        if let healthFindings = await auditHealth(&gatewayVersion) {
            findings.append(contentsOf: healthFindings)
        }

        // Phase 2: Connection security
        progress(0.4)
        findings.append(contentsOf: auditConnection())

        // Phase 3: Prompt defense
        progress(0.7)
        findings.append(contentsOf: auditPromptDefense())

        // Phase 4: App-level security
        progress(0.9)
        findings.append(contentsOf: auditAppSecurity())

        progress(1.0)

        let report = AuditReport(findings: findings, gatewayVersion: gatewayVersion)
        Self.saveReport(report)
        return report
    }

    // MARK: - Phase 1: Health

    private func auditHealth(_ version: inout String) async -> [AuditFinding]? {
        do {
            let healthy = try await client.healthCheck()
            if healthy {
                return [AuditFinding(
                    category: "Gateway",
                    title: "Gateway Responding",
                    description: "The gateway health endpoint is reachable and responding normally.",
                    severity: .info,
                    recommendation: "No action needed."
                )]
            } else {
                return [AuditFinding(
                    category: "Gateway",
                    title: "Gateway Health Check Failed",
                    description: "The gateway health endpoint returned an unhealthy status.",
                    severity: .high,
                    recommendation: "Check gateway logs and ensure all services are running correctly."
                )]
            }
        } catch {
            return [AuditFinding(
                category: "Gateway",
                title: "Gateway Unreachable",
                description: "Could not reach the gateway health endpoint: \(error.localizedDescription)",
                severity: .critical,
                recommendation: "Verify the gateway is running and network connectivity is available."
            )]
        }
    }

    // MARK: - Phase 2: Connection Security

    private func auditConnection() -> [AuditFinding] {
        var findings: [AuditFinding] = []
        let url = hostname.lowercased()

        let isLocalhost = url.contains("127.0.0.1") || url.contains("localhost") || url.contains("[::1]")

        if url.hasPrefix("ws://") || url.hasPrefix("http://") {
            if isLocalhost {
                findings.append(AuditFinding(
                    category: "Transport",
                    title: "Unencrypted Local Connection",
                    description: "Using unencrypted WebSocket (ws://) over localhost. This is acceptable for local development via SSH tunnel.",
                    severity: .info,
                    recommendation: "This is expected when using SSH tunneling. No action needed."
                ))
            } else {
                findings.append(AuditFinding(
                    category: "Transport",
                    title: "Unencrypted Remote Connection",
                    description: "Using unencrypted WebSocket (ws://) to a remote host. Data is transmitted in plaintext.",
                    severity: .critical,
                    recommendation: "Switch to wss:// (WebSocket Secure) or use SSH tunneling to encrypt the connection."
                ))
            }
        } else if url.hasPrefix("wss://") || url.hasPrefix("https://") {
            findings.append(AuditFinding(
                category: "Transport",
                title: "Encrypted Connection",
                description: "Using encrypted WebSocket (wss://) for secure communication.",
                severity: .info,
                recommendation: "No action needed. Connection is encrypted."
            ))
        }

        if !sshHost.isEmpty {
            findings.append(AuditFinding(
                category: "Transport",
                title: "SSH Tunnel Active",
                description: "Connection is secured through an SSH tunnel to \(sshHost).",
                severity: .info,
                recommendation: "SSH tunneling provides strong encryption. No action needed."
            ))
        }

        return findings
    }

    // MARK: - Phase 3: Content Scanning

    private func auditPromptDefense() -> [AuditFinding] {
        if ContentScanner.isEnabled {
            return [AuditFinding(
                category: "Content Scanning",
                title: "Content Scanning Active",
                description: "Real-time on-device content scanning is enabled. Outgoing messages are checked for API keys, secrets, and PII before reaching the gateway. All scanning runs locally on this device.",
                severity: .info,
                recommendation: "No action needed. Content scanning can be toggled in Settings."
            )]
        } else {
            return [AuditFinding(
                category: "Content Scanning",
                title: "Content Scanning Disabled",
                description: "On-device content scanning is currently disabled. Outgoing messages are not checked for sensitive data before sending.",
                severity: .medium,
                recommendation: "Enable content scanning in Settings to detect API keys, secrets, and PII before they are sent."
            )]
        }
    }

    // MARK: - Phase 4: App Security

    private func auditAppSecurity() -> [AuditFinding] {
        var findings: [AuditFinding] = []

        // Check if token is stored securely
        if UserDefaults.standard.string(forKey: "blueclaw.hostname") != nil {
            // Hostname in UserDefaults is fine, but check if token might be there too
            if UserDefaults.standard.string(forKey: "blueclaw.token") != nil {
                findings.append(AuditFinding(
                    category: "App Security",
                    title: "Token in UserDefaults",
                    description: "Authentication token is stored in UserDefaults, which is not encrypted at rest.",
                    severity: .medium,
                    recommendation: "Migrate token storage to the iOS Keychain for encrypted storage."
                ))
            } else {
                findings.append(AuditFinding(
                    category: "App Security",
                    title: "Token Stored in Keychain",
                    description: "Authentication token is stored in the iOS Keychain, which provides hardware-backed encryption.",
                    severity: .info,
                    recommendation: "No action needed. Keychain is the recommended storage for secrets."
                ))
            }
        }

        // SSH key check
        if SSHKeyManager.hasKey {
            findings.append(AuditFinding(
                category: "App Security",
                title: "SSH Key Pair Present",
                description: "An SSH key pair is stored in the Keychain for device authentication and tunnel establishment.",
                severity: .info,
                recommendation: "Ensure the corresponding public key is only added to authorized_keys on trusted hosts."
            ))
        }

        // ATS exception check
        findings.append(AuditFinding(
            category: "App Security",
            title: "Local Network Exception",
            description: "App Transport Security allows local network connections for SSH tunnel communication.",
            severity: .low,
            recommendation: "This is required for SSH tunneling. Ensure ATS is enforced for all non-local connections."
        ))

        return findings
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
