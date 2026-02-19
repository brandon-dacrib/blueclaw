import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.connectionStatus {
            case .connected:
                MainTabView()
            case .disconnected, .connecting, .error:
                ConnectionSetupView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.connectionStatus == .connected)
    }
}
