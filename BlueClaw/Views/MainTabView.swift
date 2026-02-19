import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    var body: some View {
        @Bindable var state = appState

        TabView(selection: $selectedTab) {
            Tab("Chat", systemImage: "bubble.left.fill", value: 0) {
                NavigationStack {
                    chatContent
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                HealthBadgeView()
                            }
                            ToolbarItem(placement: .principal) {
                                Text(chatTitle)
                                    .font(.headline)
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                AgentPickerView()
                            }
                        }
                }
            }

            Tab("Sessions", systemImage: "list.bullet", value: 1) {
                NavigationStack {
                    SessionListView(switchToChat: { selectedTab = 0 })
                        .navigationTitle("Sessions")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }

            Tab("Settings", systemImage: "gearshape.fill", value: 2) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .tint(AppColors.accent)
        .onAppear {
            // Start a default chat session if we have an agent
            if appState.activeSessionKey == nil {
                appState.startNewChat()
            }
        }
    }

    @ViewBuilder
    private var chatContent: some View {
        if let key = appState.activeSessionKey {
            let vm = appState.chatViewModel(for: key)
            ChatView(viewModel: vm)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(AppColors.textMuted)
                Text("Select an agent to start chatting")
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.background)
        }
    }

    private var chatTitle: String {
        if let agent = appState.selectedAgent {
            return agent.displayName
        }
        return "Chat"
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var publicKeyCopied = false

    private var connectionModeLabel: String {
        appState.savedConnectionMode?.displayName ?? "ssh+wss://"
    }

    private var isSSHMode: Bool {
        let mode = appState.savedConnectionMode ?? .sshWSS
        return mode == .sshWSS
    }

    var body: some View {
        List {
            Section("Connection") {
                HStack {
                    Text("Mode")
                    Spacer()
                    Text(connectionModeLabel)
                        .font(.callout)
                        .fontDesign(.monospaced)
                        .foregroundStyle(AppColors.textSecondary)
                }

                if isSSHMode {
                    HStack {
                        Text("SSH Host")
                        Spacer()
                        Text(appState.sshHost)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }

                    HStack {
                        Text("SSH User")
                        Spacer()
                        Text(appState.sshUser)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                } else {
                    HStack {
                        Text("Gateway")
                        Spacer()
                        Text(appState.hostname)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isHealthy ? AppColors.healthGreen : AppColors.healthRed)
                            .frame(width: 8, height: 8)
                        Text(appState.isHealthy ? "Connected" : "Disconnected")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            }

            // SSH Public Key section — always available if a key exists
            if SSHKeyManager.hasKey, let pubKey = SSHKeyManager.publicKeyOpenSSH() {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pubKey)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        UIPasteboard.general.string = pubKey
                        publicKeyCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            publicKeyCopied = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: publicKeyCopied ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.subheadline)
                            Text(publicKeyCopied ? "Copied to Clipboard" : "Copy Public Key")
                        }
                        .foregroundStyle(publicKeyCopied ? AppColors.healthGreen : AppColors.accent)
                    }
                } header: {
                    Text("SSH Public Key")
                } footer: {
                    Text("Add this key to ~/.ssh/authorized_keys on any host you want to connect to.")
                }
            }

            Section {
                Button("Disconnect", role: .destructive) {
                    Task {
                        await appState.disconnect()
                    }
                }
            }

            Section {
                NavigationLink("Open Source Licenses") {
                    LicensesView()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.background)
    }
}

// MARK: - Licenses View

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
                .padding()
        }
        .background(AppColors.background)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: nil)
                ?? Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt"),
              let text = try? String(contentsOf: url) else {
            return "License information unavailable."
        }
        return text
    }
}
