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
                   appState.connectionStatus == .connected || appState.isReconnecting {
                    backgroundSince = nil
                    Task {
                        await appState.disconnect()
                        // Reconnect using saved credentials
                        if let sshHost = appState.savedSSHHost,
                           let sshUser = appState.savedSSHUser,
                           let token = appState.savedToken(for: sshHost) {
                            await appState.connectViaSSH(sshHost: sshHost, sshUser: sshUser, token: token)
                        } else if let hostname = appState.savedHostname,
                                  let token = appState.savedToken(for: hostname) {
                            await appState.connect(hostname: hostname, token: token)
                        }
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
