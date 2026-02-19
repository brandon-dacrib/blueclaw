import SwiftUI

struct SecurityAuditView: View {
    @Environment(AppState.self) private var appState
    @State private var report: AuditReport?
    @State private var isScanning = false
    @State private var scanProgress: Double = 0
    @State private var latestVersion: String?

    var body: some View {
        Group {
            if let report {
                reportView(report)
            } else if isScanning {
                scanningView
            } else {
                initialView
            }
        }
        .background(AppColors.background)
        .navigationTitle("Security Audit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if report != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await runScan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isScanning)
                }
            }
        }
        .task {
            latestVersion = await SecurityAuditor.fetchLatestVersion()
            await runScan()
        }
    }

    // MARK: - Initial State

    private var initialView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 56))
                .foregroundStyle(AppColors.textMuted)

            Text("Security Audit")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(AppColors.textPrimary)

            Text("Scan your gateway configuration for potential security issues.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task { await runScan() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                    Text("Run Scan")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(AppColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Spacer()
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: scanProgress)
                .tint(AppColors.accent)
                .padding(.horizontal, 60)

            Text("Scanning... \(Int(scanProgress * 100))%")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)

            Spacer()
        }
    }

    // MARK: - Report

    @ViewBuilder
    private func reportView(_ report: AuditReport) -> some View {
        List {
            // Score card
            Section {
                SecurityScoreCardView(report: report, latestVersion: latestVersion)
            }
            .listRowBackground(AppColors.surface)

            // Findings grouped by category
            ForEach(report.groupedByCategory, id: \.0) { category, findings in
                Section(category) {
                    ForEach(findings) { finding in
                        SecurityFindingRow(finding: finding)
                    }
                }
            }

            // Metadata
            Section {
                HStack {
                    Text("Gateway Version")
                    Spacer()
                    if report.gatewayVersion == "Unknown" {
                        Text("Unknown")
                            .foregroundStyle(AppColors.textMuted)
                    } else if report.gatewayVersion.lowercased() == "dev" || report.gatewayVersion.lowercased().hasPrefix("dev") {
                        Text("dev (built from source)")
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                    } else {
                        Text(report.gatewayVersion)
                            .fontWeight(.medium)
                            .foregroundStyle(gatewayVersionColor(report.gatewayVersion))
                    }
                }
                if let latest = latestVersion {
                    HStack {
                        Text("Latest Gateway Release")
                        Spacer()
                        Text(latest)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
                HStack {
                    Text("Scanned")
                    Spacer()
                    Text(report.timestamp, style: .date)
                        .foregroundStyle(AppColors.textSecondary)
                    Text(report.timestamp, style: .time)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func gatewayVersionColor(_ version: String) -> Color {
        if version == "Unknown" {
            return AppColors.textMuted
        }
        // Dev builds are assumed current (built from source, likely ahead of latest release)
        if version.lowercased() == "dev" || version.lowercased().hasPrefix("dev") {
            return .green
        }
        guard let latest = latestVersion else {
            return AppColors.textSecondary
        }
        return SecurityAuditor.isVersionCurrent(version, latest: latest) ? .green : .red
    }

    // MARK: - Scan

    private func runScan() async {
        isScanning = true
        scanProgress = 0

        let auditor = SecurityAuditor(
            client: appState.client,
            hostname: appState.hostname,
            sshHost: appState.sshHost
        )

        report = await auditor.runAudit { progress in
            withAnimation {
                scanProgress = progress
            }
        }

        isScanning = false
    }
}
