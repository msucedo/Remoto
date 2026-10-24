import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
@testable import RemotoCore

/// Messages a test client received, polled by the test.
final class Inbox: @unchecked Sendable {
    enum Item: Equatable {
        case text(String)
        case closed
    }

    private let lock = NSLock()
    private var items: [Item] = []

    func push(_ item: Item) { lock.withLock { items.append(item) } }

    /// The next item, or nil on timeout.
    func next(timeout: Duration = .seconds(3)) async -> Item? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let item: Item? = lock.withLock { items.isEmpty ? nil : items.removeFirst() }
            if let item {
                // Keep reporting `closed` once seen.
                if item == .closed { lock.withLock { items.insert(.closed, at: 0) } }
                return item
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}

private final class WSClientHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    let inbox: Inbox
    init(inbox: Inbox) { self.inbox = inbox }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var data = frame.unmaskedData
            inbox.push(.text(data.readString(length: data.readableBytes) ?? ""))
        case .connectionClose:
            inbox.push(.closed)
            context.close(promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbox.push(.closed)
    }
}

private final class UpgradeRequester: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart
    let host: String
    init(host: String) { self.host = host }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/ws", headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }
}

/// A WebSocket client built on NIO's client upgrader.
final class TestWebSocket: @unchecked Sendable {
    let channel: Channel
    let inbox: Inbox
    private let group: EventLoopGroup

    private init(channel: Channel, inbox: Inbox, group: EventLoopGroup) {
        self.channel = channel
        self.inbox = inbox
        self.group = group
    }

    static func connect(port: UInt16, host: String = "localhost") async throws -> TestWebSocket {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let inbox = Inbox()
        let upgraded = group.next().makePromise(of: Void.self)
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                let upgrader = NIOWebSocketClientUpgrader(
                    maxFrameSize: 1 << 24,
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(WSClientHandler(inbox: inbox))
                        }
                    })
                let config: NIOHTTPClientUpgradeSendableConfiguration = (
                    upgraders: [upgrader], completionHandler: { _ in upgraded.succeed() }
                )
                return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(UpgradeRequester(host: "\(host):\(port)"))
                }
            }
            .connect(host: "127.0.0.1", port: Int(port)).get()
        channel.closeFuture.whenComplete { _ in upgraded.fail(ChannelError.ioOnClosedChannel) }
        try await upgraded.futureResult.get()
        return TestWebSocket(channel: channel, inbox: inbox, group: group)
    }

    func send(_ text: String) async throws {
        let buffer = channel.allocator.buffer(string: text)
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: buffer))
    }

    func send(json: JSON) async throws { try await send(json.compact) }

    func sendBinary(_ bytes: [UInt8]) async throws {
        let buffer = channel.allocator.buffer(bytes: bytes)
        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: buffer))
    }

    /// The next JSON message, nil when the socket closed or nothing came.
    func next(timeout: Duration = .seconds(3)) async -> JSON? {
        guard case .text(let text)? = await inbox.next(timeout: timeout) else { return nil }
        return try? JSON.parse(text)
    }

    /// Skips messages until one with this `t`.
    func expect(_ t: String, timeout: Duration = .seconds(3)) async -> JSON? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            guard let message = await next(timeout: deadline - clock.now) else { return nil }
            if message["t"]?.stringValue == t { return message }
        }
        return nil
    }

    /// True once the server closed the connection.
    func waitClosed(timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await inbox.next(timeout: .milliseconds(50)) == .closed { return true }
        }
        return false
    }

    func close() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

private final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let sink: NIOLockedValueBoxLike
    init(sink: NIOLockedValueBoxLike) { self.sink = sink }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        sink.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

final class NIOLockedValueBoxLike: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    func append(_ more: [UInt8]) { lock.withLock { bytes += more } }
    var value: [UInt8] { lock.withLock { bytes } }
}

struct RawResponse {
    var status: Int
    var headers: [(String, String)]
    var body: [UInt8]
    var raw: String

    func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

/// Sends raw request bytes (optionally over TLS) and reads until the server closes.
func rawHTTP(
    port: UInt16, _ request: String, tls: NIOSSLContext? = nil, serverName: String? = nil,
    verify: (@Sendable ([NIOSSLCertificate]) async -> Bool)? = nil
) async throws -> RawResponse {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let sink = NIOLockedValueBoxLike()
    let channel = try await ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                if let tls, let verify {
                    let handler = try NIOSSLClientHandler(
                        context: tls, serverHostname: serverName,
                        customVerificationCallback: { certificates, promise in
                            promise.completeWithTask { await verify(certificates) ? .certificateVerified : .failed }
                        })
                    try channel.pipeline.syncOperations.addHandler(handler)
                } else if let tls {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: tls, serverHostname: serverName))
                }
                try channel.pipeline.syncOperations.addHandler(Collector(sink: sink))
            }
        }
        .connect(host: "127.0.0.1", port: Int(port)).get()
    try await channel.writeAndFlush(channel.allocator.buffer(string: request))
    _ = try? await channel.closeFuture.get()
    try? await group.shutdownGracefully()
    return parseResponse(sink.value)
}

func parseResponse(_ bytes: [UInt8]) -> RawResponse {
    let raw = String(decoding: bytes, as: UTF8.self)
    guard let split = raw.range(of: "\r\n\r\n") else { return RawResponse(status: 0, headers: [], body: [], raw: raw) }
    let lines = raw[..<split.lowerBound].components(separatedBy: "\r\n")
    let status = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
    let headers = lines.dropFirst().compactMap { line -> (String, String)? in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
    let headerBytes = raw[..<split.upperBound].utf8.count
    return RawResponse(status: status, headers: headers, body: Array(bytes.dropFirst(headerBytes)), raw: raw)
}
