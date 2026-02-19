import SwiftUI

struct HealthBadgeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Circle()
            .fill(appState.isHealthy ? AppColors.healthGreen : AppColors.healthRed)
            .frame(width: 8, height: 8)
            .allowsHitTesting(false)
    }
}
