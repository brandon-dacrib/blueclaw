import SwiftUI
import Foundation

@main
struct BlueClawApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundSince: Date?

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .background:
                backgroundSince = Date()
            case .active:
                if let since = backgroundSince,
                   Date().timeIntervalSince(since) > 3,
                   !appState.isVoiceActive,
                   appState.connectionStatus == .connected || appState.isReconnecting {
                    backgroundSince = nil
                    // Silently reconnect transport without clearing app state
                    Task {
                        await appState.silentReconnect()
                    }
                } else {
                    backgroundSince = nil
                }
            default:
                break
            }
        }
    }
}
