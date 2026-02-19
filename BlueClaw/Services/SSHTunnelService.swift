import Foundation
@preconcurrency import Citadel
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import os.log

private let log = Logger(subsystem: "priceconsulting.BlueClaw", category: "SSHTunnel")

/// Manages an SSH tunnel: connects to a remote host, starts a local TCP listener
/// that forwards connections through SSH directTCPIP channels to `localhost:18789`
/// on the remote host.
actor SSHTunnelService {
    nonisolated enum TunnelState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected(localPort: Int)
        case error(String)

        static func == (lhs: TunnelState, rhs: TunnelState) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected): true
            case (.connecting, .connecting): true
            case (.connected(let a), .connected(let b)): a == b
            case (.error(let a), .error(let b)): a == b
            default: false
            }
        }
    }

    private(set) var state: TunnelState = .disconnected
    private var sshClient: SSHClient?
    private var localListener: Channel?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    /// Establish an SSH tunnel to the remote host. Returns the local port
    /// that the WebSocket should connect to.
    func connect(
        host: String,
        port: Int = 22,
        username: String,
        privateKey: Curve25519.Signing.PrivateKey,
        remotePort: Int = 18789
    ) async throws -> Int {
        await disconnect()
        state = .connecting

        do {
            // Build host key validator (TOFU)
            log.error("Connecting SSH to \(host, privacy: .public):\(port) as \(username, privacy: .public)")
            let validator = TOFUValidator(hostname: host)

            let settings = SSHClientSettings(
                host: host,
                port: port,
                authenticationMethod: {
                    .ed25519(username: username, privateKey: privateKey)
                },
                hostKeyValidator: .custom(validator)
            )

            log.error("Initiating SSH connection...")
            let client = try await SSHClient.connect(to: settings)
            self.sshClient = client
            log.error("SSH connected successfully")

            // Start local TCP relay
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoopGroup = group

            log.error("Starting local TCP relay for remote port \(remotePort)...")
            let localPort = try await startLocalRelay(
                group: group,
                sshClient: client,
                remoteHost: "localhost",
                remotePort: remotePort
            )
            log.error("Local relay listening on 127.0.0.1:\(localPort)")

            state = .connected(localPort: localPort)

            // Monitor SSH disconnect
            client.onDisconnect { [weak self] in
                log.warning("SSH disconnected")
                Task { [weak self] in
                    await self?.handleSSHDisconnect()
                }
            }

            return localPort
        } catch let error as BlueClawError {
            log.error("SSH tunnel failed (BlueClawError): \(error.shortDescription, privacy: .public)")
            state = .error(error.shortDescription)
            throw error
        } catch {
            log.error("SSH tunnel failed: \(String(describing: error), privacy: .public)")
            let wrapped = wrapSSHError(error, host: host)
            state = .error(wrapped.shortDescription)
            throw wrapped
        }
    }

    func disconnect() async {
        localListener?.close(promise: nil)
        localListener = nil

        try? await sshClient?.close()
        sshClient = nil

        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil

        state = .disconnected
    }

    // MARK: - Private

    private func handleSSHDisconnect() {
        localListener?.close(promise: nil)
        localListener = nil
        sshClient = nil
        state = .error("SSH tunnel disconnected")
    }

    private func startLocalRelay(
        group: EventLoopGroup,
        sshClient: SSHClient,
        remoteHost: String,
        remotePort: Int
    ) async throws -> Int {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 4)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { localChannel in
                // For each accepted local TCP connection, open an SSH directTCPIP
                // channel and relay bytes between them.
                localChannel.pipeline.addHandler(
                    SSHForwardHandler(sshClient: sshClient, remoteHost: remoteHost, remotePort: remotePort)
                )
            }

        let serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        self.localListener = serverChannel

        guard let localAddress = serverChannel.localAddress, let port = localAddress.port else {
            throw BlueClawError.sshError("Failed to bind local TCP relay")
        }

        return port
    }

    private nonisolated func wrapSSHError(_ error: any Error, host: String) -> BlueClawError {
        let desc = String(describing: error)

        if desc.contains("allAuthenticationOptionsFailed") || desc.contains("Authentication") {
            return .sshError("Authentication failed — the server may not have your SSH key in authorized_keys")
        }
        if desc.contains("connectTimeout") || desc.contains("timed out") {
            return .sshError("SSH connection timed out connecting to \(host)")
        }
        if desc.contains("InvalidHostKey") {
            return .hostKeyMismatch(host)
        }

        return .sshError(desc)
    }
}

// MARK: - TOFU Host Key Validator

/// Trust-On-First-Use host key validator.
/// Accepts the host key on first connection and stores its fingerprint.
/// Rejects connections if the host key changes.
private final class TOFUValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let hostname: String

    init(hostname: String) {
        self.hostname = hostname
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = computeFingerprint(hostKey)

        if let stored = HostKeyStore.retrieve(for: hostname) {
            if stored == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(
                    BlueClawError.hostKeyMismatch(hostname)
                )
            }
        } else {
            // First connection — trust and store
            HostKeyStore.save(fingerprint: fingerprint, for: hostname)
            validationCompletePromise.succeed(())
        }
    }

    private func computeFingerprint(_ key: NIOSSHPublicKey) -> String {
        // Serialize the public key to its wire representation and SHA-256 hash it
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &buffer)
        let keyData = Data(buffer.readableBytesView)
        let hash = SHA256.hash(data: keyData)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SSH Forward Handler

/// NIO channel handler that, when a local TCP connection is accepted,
/// opens a directTCPIP channel through SSH and relays bytes bidirectionally.
/// Buffers any data received before the SSH channel is ready.
/// Uses channel references (not contexts) for cross-event-loop safety.
private final class SSHForwardHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let sshClient: SSHClient
    private let remoteHost: String
    private let remotePort: Int
    private var sshChannel: Channel?
    private var localChannel: Channel?
    private var pendingWrites: [ByteBuffer] = []
    private var sshChannelReady = false

    init(sshClient: SSHClient, remoteHost: String, remotePort: Int) {
        self.sshClient = sshClient
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    func channelActive(context: ChannelHandlerContext) {
        self.localChannel = context.channel
        log.error("Local TCP connection accepted, opening SSH directTCPIP to \(self.remoteHost, privacy: .public):\(self.remotePort)")

        // Open a directTCPIP channel through SSH
        let originatorAddress: SocketAddress
        do {
            originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        } catch {
            log.error("Failed to create originator address")
            context.close(promise: nil)
            return
        }

        let settings = SSHChannelType.DirectTCPIP(
            targetHost: remoteHost,
            targetPort: remotePort,
            originatorAddress: originatorAddress
        )

        // Capture the local channel (thread-safe reference)
        let localChan = context.channel

        // Create the SSH channel and set up bidirectional relay
        Task { [weak self] in
            guard let self else { return }
            do {
                log.error("Creating directTCPIP channel...")
                let sshChan = try await self.sshClient.createDirectTCPIPChannel(
                    using: settings
                ) { channel in
                    // Add a handler that forwards SSH data back to local via channel reference
                    channel.pipeline.addHandler(SSHToLocalRelayHandler(localChannel: localChan))
                }
                self.sshChannel = sshChan
                self.sshChannelReady = true
                log.error("DirectTCPIP channel established, flushing \(self.pendingWrites.count) buffered writes")

                // Flush any buffered writes
                for buffer in self.pendingWrites {
                    sshChan.writeAndFlush(buffer, promise: nil)
                }
                self.pendingWrites.removeAll()
            } catch {
                log.error("Failed to create directTCPIP channel: \(String(describing: error), privacy: .public)")
                localChan.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Data came from the local TCP side → forward to SSH channel
        let buffer = self.unwrapInboundIn(data)

        if sshChannelReady, let sshChannel {
            log.error("Local->SSH: \(buffer.readableBytes) bytes")
            sshChannel.writeAndFlush(buffer, promise: nil)
        } else {
            // SSH channel not ready yet — buffer the data
            log.error("Local->SSH: buffering \(buffer.readableBytes) bytes (SSH channel not ready)")
            pendingWrites.append(buffer)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        sshChannel?.close(promise: nil)
        sshChannel = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        log.error("SSHForwardHandler error: \(String(describing: error), privacy: .public)")
        context.close(promise: nil)
    }
}

// MARK: - SSH-to-Local Relay Handler

/// Handler on the SSH directTCPIP channel that forwards data back to the local TCP socket.
/// Uses a Channel reference instead of ChannelHandlerContext for cross-event-loop safety.
private final class SSHToLocalRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let localChannel: Channel

    init(localChannel: Channel) {
        self.localChannel = localChannel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // Data came from the SSH side → forward to local TCP
        let buffer = self.unwrapInboundIn(data)
        log.error("SSH->Local: \(buffer.readableBytes) bytes")
        localChannel.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        log.error("SSH channel became inactive")
        localChannel.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        log.error("SSHToLocalRelayHandler error: \(String(describing: error), privacy: .public)")
        localChannel.close(promise: nil)
    }
}
