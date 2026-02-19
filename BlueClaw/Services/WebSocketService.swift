import Foundation

actor WebSocketService: NSObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveLoopTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<RawFrame, any Error>] = [:]
    private var eventContinuation: AsyncStream<RawFrame>.Continuation?
    private var _events: AsyncStream<RawFrame>?
    private var sessionDelegate: WebSocketSessionDelegate?

    private(set) var state: ConnectionState = .disconnected
    private var connectingURL: String = ""
    private var challengeNonce: String?
    private var challengeContinuation: CheckedContinuation<String, any Error>?

    nonisolated enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    var events: AsyncStream<RawFrame> {
        if let _events { return _events }
        let stream = AsyncStream<RawFrame> { continuation in
            self.eventContinuation = continuation
        }
        _events = stream
        return stream
    }

    func connect(hostname: String, token: String, displayName: String = "BlueClaw iOS") async throws {
        disconnect()

        state = .connecting

        // Build the WebSocket URL — enforce wss:// for security
        let urlString: String
        if hostname.hasPrefix("wss://") {
            urlString = hostname
        } else if hostname.hasPrefix("ws://") {
            // Allow ws:// only for localhost/development
            let host = hostname.replacingOccurrences(of: "ws://", with: "")
            if host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") || host.hasPrefix("[::1]") {
                urlString = hostname
            } else {
                // Upgrade to wss:// for non-local connections
                urlString = hostname.replacingOccurrences(of: "ws://", with: "wss://")
            }
        } else if hostname.contains("://") {
            urlString = hostname
                .replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "wss://")
        } else {
            urlString = "wss://\(hostname)"
        }

        guard let url = URL(string: urlString) else {
            state = .error("Invalid URL")
            throw BlueClawError.connectionFailed("Invalid hostname: \(hostname)")
        }

        connectingURL = urlString

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.tlsMinimumSupportedProtocolVersion = .TLSv12

        // Create a delegate for TLS handling
        sessionDelegate = WebSocketSessionDelegate()
        urlSession = URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Ensure the event stream is set up
        _ = events

        // Reset challenge state
        challengeNonce = nil

        startReceiveLoop()

        do {
            // Wait for the connect.challenge event from the server (contains the nonce)
            let nonce = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                challengeContinuation = continuation
            }

            // Build device identity with the nonce
            let device = SSHKeyManager.buildDeviceIdentity(token: token, nonce: nonce)
            let connectParams = ConnectParams.makeDefault(token: token, displayName: displayName, device: device)
            let response = try await send(method: GatewayMethod.connect, params: connectParams)

            guard response.ok == true else {
                let errMsg = response.error?.message ?? "Connection rejected"
                state = .error(errMsg)
                throw BlueClawError.connectionFailed(errMsg)
            }

            state = .connected
        } catch let error as BlueClawError {
            // Re-wrap disconnected/notConnected errors with the actual URL context
            switch error {
            case .notConnected, .disconnected:
                let wrappedError = BlueClawError.connectionError(
                    url: urlString,
                    underlying: "WebSocket connection failed — the server may be unreachable or refused the connection",
                    code: nil
                )
                state = .error(wrappedError.shortDescription)
                throw wrappedError
            default:
                throw error
            }
        } catch {
            let clawError = Self.wrapConnectionError(error, url: urlString)
            state = .error(clawError.shortDescription)
            throw clawError
        }
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
        state = .disconnected

        if let cont = challengeContinuation {
            challengeContinuation = nil
            cont.resume(throwing: BlueClawError.notConnected)
        }
        challengeNonce = nil

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: BlueClawError.notConnected)
        }
        pendingRequests.removeAll()

        // Reset event stream so a fresh one is created on next connection
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
    }

    func send(method: String, params: (any Encodable & Sendable)? = nil) async throws -> RawFrame {
        guard let webSocketTask, state == .connected || state == .connecting else {
            throw BlueClawError.notConnected
        }

        let request = RequestFrame(method: method, params: params)
        let data = try request.jsonData()
        let message = URLSessionWebSocketTask.Message.string(String(data: data, encoding: .utf8)!)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[request.id] = continuation
            webSocketTask.send(message) { [weak self] error in
                if let error {
                    Task { [weak self] in
                        await self?.removePendingRequest(request.id, error: error)
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func removePendingRequest(_ id: String, error: any Error) {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func startReceiveLoop() {
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let message = try await self.webSocketTask?.receive() else { break }
                    switch message {
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            await self.handleFrame(data)
                        }
                    case .data(let data):
                        await self.handleFrame(data)
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        await self.handleDisconnect(error: error)
                    }
                    break
                }
            }
        }
    }

    private func handleFrame(_ data: Data) {
        do {
            let frame = try JSONDecoder().decode(RawFrame.self, from: data)

            switch frame.type {
            case "res":
                if let id = frame.id, let continuation = pendingRequests.removeValue(forKey: id) {
                    continuation.resume(returning: frame)
                }
            case "event":
                // Intercept the connect.challenge event to extract the nonce
                if frame.event == "connect.challenge",
                   let payload = frame.payloadDictionary(),
                   let nonce = payload["nonce"] as? String {
                    challengeNonce = nonce
                    if let cont = challengeContinuation {
                        challengeContinuation = nil
                        cont.resume(returning: nonce)
                    }
                } else {
                    eventContinuation?.yield(frame)
                }
            default:
                break
            }
        } catch {
            // Silently ignore malformed frames
        }
    }

    private func handleDisconnect(error: (any Error)? = nil) {
        let wasConnected = state == .connected

        // Build a meaningful error to propagate to pending requests
        let propagatedError: any Error
        if let error {
            propagatedError = Self.wrapConnectionError(error, url: connectingURL)
        } else {
            propagatedError = BlueClawError.disconnected(reason: "Connection closed unexpectedly")
        }

        // Resume any pending challenge continuation
        if let cont = challengeContinuation {
            challengeContinuation = nil
            cont.resume(throwing: propagatedError)
        }

        if wasConnected || state == .connecting {
            if let error {
                let clawError = Self.wrapConnectionError(error, url: connectingURL)
                state = .error(clawError.shortDescription)
            } else {
                state = .disconnected
            }
        } else {
            state = .disconnected
        }

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: propagatedError)
        }
        pendingRequests.removeAll()

        if wasConnected {
            eventContinuation?.finish()
        }
    }

    /// Convert a raw URLSession/network error into a descriptive BlueClawError
    nonisolated static func wrapConnectionError(_ error: any Error, url: String) -> BlueClawError {
        let nsError = error as NSError

        // Already an BlueClawError — pass through
        if let clawError = error as? BlueClawError {
            switch clawError {
            case .connectionError:
                return clawError
            default:
                break
            }
        }

        let domain = nsError.domain
        let code = nsError.code
        let description: String

        switch (domain, code) {
        // NSURLErrorDomain codes
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            description = "Connection timed out — the server did not respond within 30 seconds"
        case (NSURLErrorDomain, NSURLErrorCannotFindHost):
            description = "Cannot find host — DNS resolution failed for the given hostname"
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            description = "Cannot connect to host — the server may be down or the port may be wrong"
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            description = "Network connection was lost during the connection attempt"
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            description = "No internet connection — check your network settings"
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed):
            description = "TLS/SSL handshake failed — the server's certificate may be invalid or untrusted"
        case (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted):
            description = "Server certificate is not trusted — it may be self-signed or expired"
        case (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate):
            description = "Server certificate has expired or is not yet valid"
        case (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid):
            description = "Server certificate is not yet valid"
        case (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot):
            description = "Server certificate has an unknown root CA — it may be self-signed"
        case (NSURLErrorDomain, NSURLErrorClientCertificateRejected):
            description = "Client certificate was rejected by the server"
        case (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            description = "DNS lookup failed — check the hostname spelling"
        case (NSURLErrorDomain, -1200): // errSSLProtocol
            description = "SSL protocol error — the server may not support TLS 1.2+"
        default:
            // Fall back to the localized description
            description = nsError.localizedDescription
        }

        return .connectionError(url: url, underlying: description, code: code)
    }
}

// MARK: - URLSession Delegate for TLS

private final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        // Use default TLS validation
        return (.useCredential, URLCredential(trust: serverTrust))
    }
}
