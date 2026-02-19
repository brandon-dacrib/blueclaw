import Foundation
import SwiftUI

enum AuditSeverity: String, Codable, CaseIterable, Sendable {
    case critical
    case high
    case medium
    case low
    case info

    var displayName: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        case .info: .gray
        }
    }

    var icon: String {
        switch self {
        case .critical: "C"
        case .high: "H"
        case .medium: "M"
        case .low: "L"
        case .info: "i"
        }
    }
}

struct AuditFinding: Identifiable, Codable, Sendable {
    let id: UUID
    let category: String
    let title: String
    let description: String
    let severity: AuditSeverity
    let recommendation: String

    init(category: String, title: String, description: String, severity: AuditSeverity, recommendation: String) {
        self.id = UUID()
        self.category = category
        self.title = title
        self.description = description
        self.severity = severity
        self.recommendation = recommendation
    }
}

struct AuditReport: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let findings: [AuditFinding]
    let gatewayVersion: String

    init(findings: [AuditFinding], gatewayVersion: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.findings = findings
        self.gatewayVersion = gatewayVersion
    }

    var overallScore: Int {
        guard !findings.isEmpty else { return 100 }
        let penalty = findings.reduce(0) { sum, f in
            switch f.severity {
            case .critical: sum + 25
            case .high: sum + 15
            case .medium: sum + 8
            case .low: sum + 3
            case .info: sum + 0
            }
        }
        return max(0, 100 - penalty)
    }

    var scoreLabel: String {
        switch overallScore {
        case 80...100: "Good"
        case 60..<80: "Fair"
        case 40..<60: "Needs Attention"
        default: "Critical"
        }
    }

    var scoreColor: Color {
        switch overallScore {
        case 80...100: .green
        case 60..<80: .yellow
        case 40..<60: .orange
        default: .red
        }
    }

    func count(for severity: AuditSeverity) -> Int {
        findings.filter { $0.severity == severity }.count
    }

    var groupedByCategory: [(String, [AuditFinding])] {
        let categories = Dictionary(grouping: findings, by: \.category)
        return categories.sorted { $0.key < $1.key }
    }
}
