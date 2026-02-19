import Foundation
import UIKit

nonisolated struct ConnectParams: Codable, Sendable {
    let minProtocol: Int
    let maxProtocol: Int
    let client: ClientInfo
    let role: String
    let scopes: [String]
    let auth: AuthInfo
    let device: DeviceInfo?

    static func makeDefault(token: String, displayName: String = "BlueClaw iOS", device: DeviceInfo? = nil) -> ConnectParams {
        ConnectParams(
            minProtocol: 3,
            maxProtocol: 3,
            client: ClientInfo(
                id: "openclaw-ios",
                displayName: displayName,
                version: "1.0.0",
                platform: "ios",
                mode: "node"
            ),
            role: "operator",
            scopes: ["operator.admin"],
            auth: AuthInfo(token: token),
            device: device
        )
    }

    @MainActor
    static func resolveDisplayName() -> String {
        let deviceName = UIDevice.current.name
        let baseName: String

        // If the device has a custom name (not just generic defaults), use it
        if !deviceName.isEmpty
            && deviceName != "iPhone"
            && deviceName != "iPad"
            && deviceName != "iPod touch" {
            baseName = deviceName
        } else {
            // Fallback based on idiom
            switch UIDevice.current.userInterfaceIdiom {
            case .phone:
                baseName = "iPhone"
            case .pad:
                baseName = "iPad"
            default:
                baseName = "iOS Device"
            }
        }

        return "\(baseName) (BlueClaw)"
    }
}

nonisolated struct ClientInfo: Codable, Sendable {
    let id: String
    let displayName: String?
    let version: String
    let platform: String
    let mode: String
}

nonisolated struct AuthInfo: Codable, Sendable {
    let token: String?
    let password: String?

    init(token: String? = nil, password: String? = nil) {
        self.token = token
        self.password = password
    }
}

nonisolated struct DeviceInfo: Codable, Sendable {
    let id: String
    let publicKey: String
    let signature: String
    let signedAt: Int
    let nonce: String?
}

nonisolated struct HelloOkPayload: Codable, Sendable {
    let type: String?
    let `protocol`: Int?
    let server: ServerInfo?
    let features: Features?

    nonisolated struct ServerInfo: Codable, Sendable {
        let version: String?
        let commit: String?
        let host: String?
        let connId: String?
    }

    nonisolated struct Features: Codable, Sendable {
        let methods: [String]?
        let events: [String]?
    }
}
