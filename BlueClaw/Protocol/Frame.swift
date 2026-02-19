import Foundation

// MARK: - Incoming frame discrimination

nonisolated struct RawFrame: Codable, Sendable {
    let type: String
    let id: String?
    let method: String?
    let ok: Bool?
    let event: String?
    let payload: AnyCodable?
    let error: FrameError?
    let seq: Int?
}

nonisolated struct FrameError: Codable, Sendable {
    let code: String?
    let message: String?
}

// MARK: - Outgoing request

nonisolated struct RequestFrame: Sendable {
    let id: String
    let method: String
    let params: (any Encodable & Sendable)?

    init(method: String, params: (any Encodable & Sendable)? = nil) {
        self.id = UUID().uuidString
        self.method = method
        self.params = params
    }

    func jsonData() throws -> Data {
        var dict: [String: Any] = [
            "type": "req",
            "id": id,
            "method": method,
        ]
        if let params {
            let encoded = try JSONEncoder().encode(AnyEncodableWrapper(params))
            let parsed = try JSONSerialization.jsonObject(with: encoded)
            dict["params"] = parsed
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - Helper to encode any Encodable

private nonisolated struct AnyEncodableWrapper: Encodable {
    let wrapped: any Encodable

    init(_ wrapped: any Encodable) {
        self.wrapped = wrapped
    }

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}

// MARK: - Payload decoding helpers

extension RawFrame {
    func decodePayload<T: Decodable>(as type: T.Type) throws -> T {
        guard let payload else {
            throw BlueClawError.missingPayload
        }
        let data = try JSONSerialization.data(withJSONObject: payload.value)
        return try JSONDecoder().decode(type, from: data)
    }

    func payloadDictionary() -> [String: Any]? {
        payload?.dictionary
    }
}

nonisolated enum BlueClawError: Error, LocalizedError, Sendable {
    case missingPayload
    case serverError(code: String?, message: String?)
    case connectionFailed(String)
    case connectionError(url: String, underlying: String, code: Int?)
    case notConnected
    case disconnected(reason: String)
    case timeout
    case unexpectedResponse
    case sshError(String)
    case hostKeyMismatch(String)

    var errorDescription: String? {
        switch self {
        case .missingPayload: "Missing payload in response"
        case .serverError(_, let message): message ?? "Server error"
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .connectionError(_, let underlying, _): underlying
        case .notConnected: "Not connected to server"
        case .disconnected(let reason): reason
        case .timeout: "Request timed out"
        case .unexpectedResponse: "Unexpected response from server"
        case .sshError(let reason): "SSH error: \(reason)"
        case .hostKeyMismatch(let host): "SSH host key changed for \(host)"
        }
    }

    /// User-friendly short summary for display
    var shortDescription: String {
        switch self {
        case .connectionError(_, let underlying, _):
            if underlying.contains("certificate") || underlying.contains("SSL") || underlying.contains("TLS") {
                return "TLS/SSL certificate error"
            } else if underlying.contains("Could not connect") || underlying.contains("Network is unreachable") {
                return "Could not reach server"
            } else if underlying.contains("timed out") {
                return "Connection timed out"
            } else if underlying.contains("DNS") || underlying.contains("name resolution") {
                return "DNS resolution failed"
            }
            return "Connection error"
        case .connectionFailed(let reason):
            return reason
        case .sshError:
            return "SSH connection failed"
        case .hostKeyMismatch:
            return "SSH host key changed"
        default:
            return errorDescription ?? "Unknown error"
        }
    }

    /// Full technical detail for the expandable error view
    var technicalDetail: String {
        switch self {
        case .connectionError(let url, let underlying, let code):
            var detail = "URL: \(url)\nError: \(underlying)"
            if let code {
                detail += "\nCode: \(code)"
            }
            return detail
        case .serverError(let code, let message):
            var detail = "Server error"
            if let code { detail += " [\(code)]" }
            if let message { detail += ": \(message)" }
            return detail
        case .sshError(let reason):
            return "SSH: \(reason)"
        case .hostKeyMismatch(let host):
            return "The SSH host key for \(host) has changed since last connection.\nThis could indicate a security issue (man-in-the-middle attack) or the server was reinstalled.\nIf you trust this change, disconnect and reconnect to accept the new key."
        default:
            return errorDescription ?? "Unknown error"
        }
    }
}
