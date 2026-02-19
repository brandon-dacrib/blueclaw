import Foundation
import LocalAuthentication

nonisolated enum BiometricAuth {
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

    static func authenticate(reason: String = "Authenticate to access your OpenClaw gateway") async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            return false
        }
    }
}
