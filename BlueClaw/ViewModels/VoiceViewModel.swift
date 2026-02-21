import Foundation
import os.log

private let log = Logger(subsystem: "priceconsulting.BlueClaw", category: "VoiceViewModel")

@Observable
@MainActor
final class VoiceViewModel {
    let voiceService = VoiceInputService()
    private let client: GatewayClient
    private let sessionKeyProvider: () -> String?

    var exchanges: [VoiceExchange] = []
    var streamingContent: String = ""
    var isWaiting = false
    var isContinuousMode = false
    var error: String?
    var sensitiveWarning: [SensitiveMatch]?
    var pendingVoiceText: String?

    private var currentRunId: String?

    init(client: GatewayClient, sessionKeyProvider: @escaping () -> String?) {
        self.client = client
        self.sessionKeyProvider = sessionKeyProvider

        voiceService.onFinalTranscription = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                await self.sendVoiceMessage(text)
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if voiceService.isRecording {
            voiceService.stopRecording()
        } else {
            // Ensure background audio is running so voice survives screen lock
            voiceService.startBackgroundAudio()
            voiceService.startRecording()
        }
    }

    func toggleContinuousMode() {
        isContinuousMode.toggle()
    }

    // MARK: - Send

    private func sendVoiceMessage(_ text: String) async {
        // Scan for sensitive content before sending
        let matches = ContentScanner.scan(text)
        if !matches.isEmpty {
            pendingVoiceText = text
            sensitiveWarning = matches
            return
        }

        await performVoiceSend(text)
    }

    private func performVoiceSend(_ text: String) async {
        guard let sessionKey = sessionKeyProvider() else {
            error = "No active session"
            return
        }

        let exchange = VoiceExchange(userText: text)
        exchanges.append(exchange)
        isWaiting = true
        streamingContent = ""
        error = nil

        let hint = "[Voice message - respond naturally and conversationally, keep response concise for speech] "

        do {
            try await client.sendMessage(sessionKey: sessionKey, message: hint + text)
        } catch {
            isWaiting = false
            self.error = error.localizedDescription
        }
    }

    // MARK: - Sensitive Content

    func confirmSend() async {
        let text = pendingVoiceText
        sensitiveWarning = nil
        pendingVoiceText = nil
        if let text {
            await performVoiceSend(text)
        }
    }

    func cancelSend() {
        sensitiveWarning = nil
        pendingVoiceText = nil
    }

    // MARK: - Event Handling

    func handleChatEvent(_ event: ChatEventPayload) {
        switch event.state {
        case .delta:
            isWaiting = true
            currentRunId = event.runId
            if let delta = event.contentDelta {
                streamingContent += delta
            }

        case .final_:
            let finalContent = event.fullContent ?? streamingContent
            if !finalContent.isEmpty, !exchanges.isEmpty {
                exchanges[exchanges.count - 1].assistantText = finalContent
            }
            isWaiting = false
            streamingContent = ""
            currentRunId = nil

            // Speak the response, then resume recording if continuous mode
            if !finalContent.isEmpty {
                voiceService.speak(finalContent) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.isContinuousMode else { return }
                        self.voiceService.startRecording()
                    }
                }
            }

        case .aborted:
            if !streamingContent.isEmpty, !exchanges.isEmpty {
                exchanges[exchanges.count - 1].assistantText = streamingContent + " [aborted]"
            }
            isWaiting = false
            streamingContent = ""
            currentRunId = nil

        case .error:
            isWaiting = false
            streamingContent = ""
            currentRunId = nil
            error = "Generation failed"
        }
    }

    // MARK: - Cleanup

    func stop() {
        voiceService.stopRecording()
        voiceService.stopSpeaking()
        voiceService.deactivateAudioSession()
    }
}
