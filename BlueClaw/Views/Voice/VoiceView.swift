import SwiftUI

struct VoiceView: View {
    @Environment(AppState.self) private var appState
    @State private var voiceVM: VoiceViewModel?
    @State private var permissionsGranted = false
    @State private var permissionsChecked = false

    var body: some View {
        Group {
            if let vm = voiceVM {
                voiceContent(vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.background)
            }
        }
        .onAppear {
            setupViewModel()
        }
    }

    private func setupViewModel() {
        guard voiceVM == nil else { return }
        let vm = appState.voiceViewModel()
        self.voiceVM = vm
    }

    @ViewBuilder
    private func voiceContent(_ vm: VoiceViewModel) -> some View {
        VStack(spacing: 0) {
            // Conversation history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(vm.exchanges) { exchange in
                            VoiceExchangeRow(exchange: exchange)
                                .id(exchange.id)
                        }

                        // Streaming indicator
                        if vm.isWaiting && !vm.streamingContent.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "cpu")
                                    .font(.caption)
                                    .foregroundStyle(AppColors.textMuted)
                                    .frame(width: 20)
                                Text(vm.streamingContent + "...")
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .id("streaming")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .onChange(of: vm.exchanges.count) {
                    if let last = vm.exchanges.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Orb
            VoiceOrbView(
                audioLevel: vm.voiceService.audioLevel,
                isActive: vm.voiceService.isRecording || vm.voiceService.isSpeaking
            )
            .frame(width: 160, height: 160)
            .padding(.vertical, 8)

            // Live transcript
            if vm.voiceService.isRecording && !vm.voiceService.transcription.isEmpty {
                Text(vm.voiceService.transcription)
                    .font(.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 4)
            } else if vm.isWaiting {
                Text("Thinking...")
                    .font(.callout)
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.bottom, 4)
            } else if vm.voiceService.isSpeaking {
                Text("Speaking...")
                    .font(.callout)
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.bottom, 4)
            }

            // Error
            if let error = vm.error ?? vm.voiceService.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AppColors.accent)
                    .padding(.bottom, 4)
            }

            Spacer(minLength: 0)

            // Controls
            controlBar(vm)
                .padding(.bottom, 24)
        }
        .background(AppColors.background)
        .task {
            if !permissionsChecked {
                permissionsChecked = true
                permissionsGranted = await vm.voiceService.requestPermissions()
            }
        }
        .alert(
            "Sensitive Content Detected",
            isPresented: Binding(
                get: { vm.sensitiveWarning != nil },
                set: { if !$0 { vm.cancelSend() } }
            )
        ) {
            Button("Send Anyway", role: .destructive) {
                Task { await vm.confirmSend() }
            }
            Button("Edit Message", role: .cancel) {
                vm.cancelSend()
            }
        } message: {
            if let matches = vm.sensitiveWarning {
                Text("Your voice message may contain sensitive data that will be sent to the server:\n\n"
                     + matches.map { "- \($0.category): \($0.matched)" }.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private func controlBar(_ vm: VoiceViewModel) -> some View {
        HStack(spacing: 32) {
            // Continuous mode toggle
            Button {
                vm.toggleContinuousMode()
            } label: {
                Image(systemName: vm.isContinuousMode ? "infinity.circle.fill" : "infinity.circle")
                    .font(.title2)
                    .foregroundStyle(vm.isContinuousMode ? AppColors.accent : AppColors.textMuted)
            }

            // Main record button
            Button {
                if permissionsGranted {
                    vm.toggleRecording()
                } else {
                    vm.error = "Microphone and speech permissions required"
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(vm.voiceService.isRecording ? AppColors.accent : AppColors.surface)
                        .frame(width: 72, height: 72)
                        .overlay(
                            Circle()
                                .stroke(AppColors.surfaceBorder, lineWidth: 1)
                        )

                    Image(systemName: vm.voiceService.isRecording ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .foregroundStyle(vm.voiceService.isRecording ? .white : AppColors.accent)
                }
            }
            .disabled(vm.isWaiting || vm.voiceService.isSpeaking)

            // Stop speaking button
            Button {
                vm.voiceService.stopSpeaking()
            } label: {
                Image(systemName: "speaker.slash.fill")
                    .font(.title2)
                    .foregroundStyle(vm.voiceService.isSpeaking ? AppColors.accent : AppColors.textMuted)
            }
            .disabled(!vm.voiceService.isSpeaking)
        }
    }
}
