import Foundation
import LocalAuthentication

nonisolated enum BiometricAuth {
    /// How long after a successful authentication before requiring re-auth (30 minutes)
    private static let gracePeriod: TimeInterval = 30 * 60

    private static let lastAuthKey = "blueclaw.lastAuthenticatedAt"

    enum BiometricType {
        case faceID
        case touchID
        case none
    }

    static var availableType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    static var isAvailable: Bool {
        availableType != .none
    }

    static var biometricName: String {
        switch availableType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .none: "Biometrics"
        }
    }

    static var biometricIcon: String {
        switch availableType {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .none: "lock.fill"
        }
    }

    /// Whether the user is still within the grace period from a previous authentication.
    static var isWithinGracePeriod: Bool {
        let lastAuth = UserDefaults.standard.double(forKey: lastAuthKey)
        guard lastAuth > 0 else { return false }
        return Date().timeIntervalSince1970 - lastAuth < gracePeriod
    }

    /// Record a successful authentication timestamp.
    static func recordAuthentication() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAuthKey)
    }

    static func authenticate(reason: String = "Authenticate to access your OpenClaw gateway") async -> Bool {
        // Skip if within grace period
        if isWithinGracePeriod { return true }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        do {
            let result = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            if result {
                recordAuthentication()
            }
            return result
        } catch {
            return false
        }
    }
}
