import SwiftUI

struct ConnectionSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ConnectionViewModel()
    @State private var showQRScanner = false
    @State private var showManualEntry = false
    @State private var showErrorDetail = false

    var body: some View {
        ZStack {
            AppColors.background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 60)

                    // Logo area
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(AppColors.accent.opacity(0.1))
                                .frame(width: 100, height: 100)
                            Circle()
                                .fill(AppColors.accent.opacity(0.05))
                                .frame(width: 130, height: 130)
                            Image(systemName: "bolt.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(AppColors.accent)
                        }

                        Text("BlueClaw")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(AppColors.textPrimary)

                        Text("Connect to your gateway")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(.bottom, 40)

                    // Quick reconnect with biometrics (if saved credentials exist)
                    if viewModel.hasSavedCredentials {
                        VStack(spacing: 16) {
                            Button {
                                Task {
                                    await viewModel.authenticateAndConnect(appState: appState)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    if viewModel.isConnecting {
                                        ProgressView()
                                            .tint(.white)
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: BiometricAuth.biometricIcon)
                                            .font(.system(size: 24))
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Reconnect to \(viewModel.effectiveHost)")
                                            .fontWeight(.semibold)
                                            .lineLimit(1)
                                        Text("Authenticate with \(BiometricAuth.biometricName)")
                                            .font(.caption)
                                            .opacity(0.8)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .opacity(0.6)
                                }
                                .padding(16)
                                .foregroundStyle(.white)
                                .background(AppColors.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .disabled(viewModel.isConnecting)
                            .padding(.horizontal, 32)

                            // Error
                            if viewModel.errorMessage != nil {
                                connectionErrorCard
                                    .padding(.horizontal, 32)
                            }

                            // Divider
                            HStack(spacing: 12) {
                                Rectangle()
                                    .fill(AppColors.surfaceBorder)
                                    .frame(height: 1)
                                Text("or")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textMuted)
                                Rectangle()
                                    .fill(AppColors.surfaceBorder)
                                    .frame(height: 1)
                            }
                            .padding(.horizontal, 32)
                            .padding(.top, 4)

                            // Manual entry button
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    showManualEntry = true
                                    viewModel.hasSavedCredentials = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "keyboard")
                                    Text("Manual Setup")
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(AppColors.textPrimary)
                                .background(AppColors.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(AppColors.surfaceBorder, lineWidth: 1)
                                )
                            }
                            .padding(.horizontal, 32)
                        }
                    } else {
                        // No saved credentials — show manual form
                        manualEntryCard
                    }

                    // Security note
                    HStack(spacing: 6) {
                        Image(systemName: securityIcon)
                            .font(.caption2)
                        Text(securityNote)
                            .font(.caption2)
                    }
                    .foregroundStyle(securityNoteColor)
                    .padding(.top, 24)

                    Spacer(minLength: 60)
                }
            }
        }
        .onAppear {
            viewModel.loadSavedCredentials(from: appState)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerSheet(viewModel: $viewModel, appState: appState)
        }
    }

    // MARK: - Security Note Helpers

    private var securityIcon: String {
        switch viewModel.connectionMode {
        case .sshWSS: "lock.shield.fill"
        case .wss: "lock.fill"
        case .ws: "exclamationmark.triangle.fill"
        }
    }

    private var securityNote: String {
        switch viewModel.connectionMode {
        case .sshWSS: "SSH tunnel + Keychain + \(BiometricAuth.biometricName)"
        case .wss: "TLS encrypted + Keychain + \(BiometricAuth.biometricName)"
        case .ws: "Unencrypted connection \u{2014} use only on trusted networks"
        }
    }

    private var securityNoteColor: Color {
        switch viewModel.connectionMode {
        case .sshWSS: AppColors.textMuted
        case .wss: AppColors.textMuted
        case .ws: .orange
        }
    }

    // MARK: - Manual Entry Card

    private var manualEntryCard: some View {
        VStack(spacing: 20) {
            // Connection mode picker
            connectionModePicker

            // ws:// insecure warning
            if viewModel.connectionMode == .ws {
                insecureWarningBanner
            }

            Divider()
                .background(AppColors.surfaceBorder)

            // SSH Key section (only for ssh+wss mode)
            if viewModel.connectionMode.needsSSH {
                sshKeySection

                Divider()
                    .background(AppColors.surfaceBorder)
            }

            // Host field
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.connectionMode.needsSSH ? "SSH Host" : "Gateway Host")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)

                TextField("", text: $viewModel.host, prompt: Text("server.example.com").foregroundStyle(AppColors.textMuted))
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(14)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(hostBorderColor, lineWidth: 1)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                if case .invalid(let msg) = viewModel.hostValidation {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(AppColors.accent)
                }
            }

            // SSH User field (only for ssh+wss mode)
            if viewModel.connectionMode.needsSSH {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SSH User")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.textSecondary)
                        .textCase(.uppercase)

                    TextField("", text: $viewModel.sshUser, prompt: Text("username").foregroundStyle(AppColors.textMuted))
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(14)
                        .background(AppColors.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppColors.inputBorder, lineWidth: 1)
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            // Port field (for direct modes)
            if viewModel.connectionMode.needsPort {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Port")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.textSecondary)
                        .textCase(.uppercase)

                    TextField("", text: $viewModel.port, prompt: Text(defaultPortHint).foregroundStyle(AppColors.textMuted))
                        .textFieldStyle(.plain)
                        .font(.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .padding(14)
                        .background(AppColors.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AppColors.inputBorder, lineWidth: 1)
                        )
                        .keyboardType(.numberPad)
                }
            }

            // Connection preview
            if let preview = viewModel.connectionPreview {
                HStack(spacing: 6) {
                    Image(systemName: previewIcon)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textMuted)
                    Text(preview)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Token field
            VStack(alignment: .leading, spacing: 8) {
                Text("Gateway Token")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)

                SecureField("", text: $viewModel.token, prompt: Text("Enter your token").foregroundStyle(AppColors.textMuted))
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(14)
                    .background(AppColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(AppColors.inputBorder, lineWidth: 1)
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if viewModel.errorMessage != nil {
                connectionErrorCard
            }

            Button {
                Task {
                    await viewModel.connect(appState: appState)
                }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isConnecting {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    Text(viewModel.isConnecting ? "Connecting..." : "Connect")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(viewModel.canConnect ? AppColors.accent : AppColors.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!viewModel.canConnect)
            .padding(.top, 4)
        }
        .padding(24)
        .background(AppColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(AppColors.surfaceBorder, lineWidth: 1)
        )
        .padding(.horizontal, 32)
    }

    // MARK: - Connection Mode Picker

    private var connectionModePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection Mode")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(AppColors.textSecondary)
                .textCase(.uppercase)

            HStack(spacing: 0) {
                ForEach(ConnectionViewModel.ConnectionMode.allCases) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.connectionMode = mode
                        }
                    } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: modeIcon(mode))
                                    .font(.caption2)
                                Text(mode.shortLabel)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                            }
                            if mode == .sshWSS {
                                Text("Recommended")
                                    .font(.system(size: 8, weight: .bold))
                                    .textCase(.uppercase)
                                    .foregroundStyle(viewModel.connectionMode == mode ? .white.opacity(0.8) : AppColors.healthGreen)
                            } else {
                                Text(mode == .wss ? "Encrypted" : "Insecure")
                                    .font(.system(size: 8, weight: .medium))
                                    .textCase(.uppercase)
                                    .foregroundStyle(
                                        viewModel.connectionMode == mode
                                            ? .white.opacity(0.7)
                                            : (mode == .ws ? .orange : AppColors.textMuted)
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            viewModel.connectionMode == mode
                                ? modeSelectedColor(mode)
                                : Color.clear
                        )
                        .foregroundStyle(
                            viewModel.connectionMode == mode
                                ? .white
                                : AppColors.textPrimary
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(AppColors.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(AppColors.inputBorder, lineWidth: 1)
            )

            Text(viewModel.connectionMode.description)
                .font(.caption2)
                .foregroundStyle(AppColors.textMuted)
        }
    }

    private func modeIcon(_ mode: ConnectionViewModel.ConnectionMode) -> String {
        switch mode {
        case .sshWSS: "lock.shield.fill"
        case .wss: "lock.fill"
        case .ws: "lock.open.fill"
        }
    }

    private func modeSelectedColor(_ mode: ConnectionViewModel.ConnectionMode) -> Color {
        switch mode {
        case .sshWSS: AppColors.accent
        case .wss: .blue
        case .ws: .orange
        }
    }

    // MARK: - Insecure Warning

    private var insecureWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Insecure Connection")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.orange)
                Text("Your token and all data will be sent unencrypted. Only use ws:// on trusted local networks. Consider ssh+wss:// for secure remote access.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - SSH Key Section

    private var sshKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.accent)
                Text("SSH Key")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppColors.textSecondary)
                    .textCase(.uppercase)
                Spacer()
            }

            if viewModel.hasSSHKey, let pubKey = viewModel.publicKeyString {
                // Show public key
                VStack(alignment: .leading, spacing: 8) {
                    Text(pubKey)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(AppColors.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = pubKey
                            viewModel.publicKeyCopied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                viewModel.publicKeyCopied = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: viewModel.publicKeyCopied ? "checkmark" : "doc.on.doc")
                                    .font(.caption2)
                                Text(viewModel.publicKeyCopied ? "Copied" : "Copy Public Key")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(viewModel.publicKeyCopied ? AppColors.healthGreen : AppColors.accent)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppColors.healthGreen)
                        Text("Key ready")
                            .font(.caption2)
                            .foregroundStyle(AppColors.healthGreen)
                    }

                    Text("Add this key to ~/.ssh/authorized_keys on your server")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textMuted)
                }
            } else {
                // No key — generate button
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generate an Ed25519 SSH key to connect securely.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)

                    Button {
                        viewModel.generateSSHKey()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.fill")
                                .font(.caption)
                            Text("Generate SSH Key")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(AppColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var hostBorderColor: Color {
        switch viewModel.hostValidation {
        case .empty: AppColors.inputBorder
        case .valid: AppColors.healthGreen.opacity(0.4)
        case .invalid: AppColors.accent.opacity(0.6)
        }
    }

    private var defaultPortHint: String {
        switch viewModel.connectionMode {
        case .sshWSS: "22"
        case .wss: "443"
        case .ws: "18789"
        }
    }

    private var previewIcon: String {
        switch viewModel.connectionMode {
        case .sshWSS: "terminal.fill"
        case .wss: "lock.fill"
        case .ws: "network"
        }
    }

    // MARK: - Error Card

    private var connectionErrorCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showErrorDetail.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.accent)

                    Text(viewModel.errorMessage ?? "Connection failed")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(AppColors.textPrimary)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    if viewModel.errorDetail != nil {
                        Image(systemName: showErrorDetail ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textMuted)
                    }
                }
            }
            .buttonStyle(.plain)

            if showErrorDetail, let detail = viewModel.errorDetail {
                Divider()
                    .background(AppColors.surfaceBorder)
                    .padding(.vertical, 10)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(AppColors.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppColors.accent.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - QR Scanner Sheet

struct QRScannerSheet: View {
    @Binding var viewModel: ConnectionViewModel
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScannerView { code in
                handleScannedCode(code)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(AppColors.accent)
                }
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        if let url = URL(string: code), url.scheme == "blueclaw" {
            viewModel.host = url.host ?? ""
            if let token = url.queryItems?["token"] {
                viewModel.token = token
                if let user = url.queryItems?["user"] {
                    viewModel.sshUser = user
                }
                if let mode = url.queryItems?["mode"],
                   let connMode = ConnectionViewModel.ConnectionMode(rawValue: mode) {
                    viewModel.connectionMode = connMode
                }
                Task {
                    await viewModel.connect(appState: appState)
                }
            }
        } else if let data = code.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            if let host = json["host"] ?? json["hostname"] {
                viewModel.host = host
            }
            if let user = json["user"] ?? json["username"] {
                viewModel.sshUser = user
            }
            if let mode = json["mode"],
               let connMode = ConnectionViewModel.ConnectionMode(rawValue: mode) {
                viewModel.connectionMode = connMode
            }
            if let token = json["token"] {
                viewModel.token = token
                Task {
                    await viewModel.connect(appState: appState)
                }
            }
        } else {
            viewModel.host = code
        }
    }
}

// MARK: - URL helper

private extension URL {
    var queryItems: [String: String]? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        return Dictionary(items.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { _, last in last })
    }
}
