import Darwin
import NIOCore
import NIOPosix

/// The IPv4 and IPv6 listeners on one port (SPEC §4.1).
final class Listener: Sendable {
    static let attempts = 20

    let group: MultiThreadedEventLoopGroup
    let channels: [Channel]
    let port: UInt16

    private init(group: MultiThreadedEventLoopGroup, channels: [Channel], port: UInt16) {
        self.group = group
        self.channels = channels
        self.port = port
    }

    static func candidatePorts(preferred: UInt16) -> [Int] {
        guard preferred != 0 else { return [0] }
        return (0..<attempts).map { Int(preferred) + $0 }.filter { $0 <= 65535 }
    }

    static func open(core: HostCore, preferred: UInt16) async throws -> (Listener, preferredTaken: Bool) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        for loop in group.makeIterator() {
            loop.execute { pthread_setname_np("remoto-net") }
        }
        var lastError: Error?
        for port in candidatePorts(preferred: preferred) {
            let v4: Channel
            do {
                v4 = try await bootstrap(core: core, group: group, v6only: false).bind(host: "0.0.0.0", port: port).get()
            } catch {
                lastError = error
                continue
            }
            let actual = v4.localAddress?.port ?? port
            var channels = [v4]
            do {
                channels.append(
                    try await bootstrap(core: core, group: group, v6only: true).bind(host: "::", port: actual).get())
            } catch {
                Log.warning("net", "IPv6 listener on port \(actual) failed (\(error)); continuing with IPv4 only")
            }
            Log.info("net", "listening on port \(actual)")
            let taken = preferred != 0 && actual != Int(preferred)
            return (Listener(group: group, channels: channels, port: UInt16(actual)), taken)
        }
        try? await group.shutdownGracefully()
        throw HostError(lastError.map { "No port available: \($0)" } ?? "No port available.")
    }

    private static func bootstrap(core: HostCore, group: EventLoopGroup, v6only: Bool) -> ServerBootstrap {
        var bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        if v6only {
            bootstrap = bootstrap.serverChannelOption(
                ChannelOptions.Types.SocketOption(level: .ipv6, name: .ipv6_v6only), value: 1)
        }
        return bootstrap
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in core.accept(channel) }
    }

    func close(connections: ConnectionTracker) async {
        for channel in channels { try? await channel.close() }
        for channel in connections.channels { try? await channel.close() }
        try? await group.shutdownGracefully()
    }
}

extension HostCore {
    /// New TCP connection: apply limits, then sniff for TLS (SPEC §4.2, §4.3).
    func accept(_ channel: Channel) -> EventLoopFuture<Void> {
        let ip = channel.remoteAddress?.ipAddress ?? ""
        guard let ticket = connections.admit(ip: ip, channel: channel, allowLocalProxy: config.allowLocalProxy) else {
            Log.info("net", "connection from \(ip) refused: too many open connections")
            return channel.close()
        }
        let tracker = connections
        channel.closeFuture.whenComplete { _ in tracker.release(ticket) }
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(ProtocolSniffer(core: self, peerIP: ip))
        }
    }
}
