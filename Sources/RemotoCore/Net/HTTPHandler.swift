import NIOCore
import NIOHTTP1
import NIOWebSocket

/// One HTTP/1.1 connection: validation, routing, keep-alive and the upgrade
/// to WebSocket (SPEC §4.5–§4.9).
///
/// Defenses against unauthenticated clients: no new reads while a request is
/// being answered, at most 4 pipelined requests waiting, requests with a body
/// refused as soon as their head arrives, and the header timer runs until the
/// whole request (`.end`) is in.
final class HTTPHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    /// Largest WebSocket frame accepted (the SPEC says 16 MiB; see docs/CONFORMANCE.md).
    static let maxFrameSize = 512 << 10
    static let maxQueued = 4

    private let core: HostCore
    private let peerIP: String
    private let tls: Bool
    private let openedAt = Mono.now()
    private let decoder: ByteToMessageHandler<HTTPRequestDecoder>
    private let encoder: HTTPResponseEncoder
    private var served = 0
    private var queue: [HTTPRequestHead] = []
    private var current: HTTPRequestHead?
    private var busy = false
    private var upgrading = false
    private var rejected = false
    /// Too many pipelined requests: answer the queued ones, then close.
    private var overflowed = false
    private var pendingRead = false
    private var timer: Scheduled<Void>?

    init(
        core: HostCore, peerIP: String, tls: Bool, decoder: ByteToMessageHandler<HTTPRequestDecoder>,
        encoder: HTTPResponseEncoder
    ) {
        self.core = core
        self.peerIP = peerIP
        self.tls = tls
        self.decoder = decoder
        self.encoder = encoder
    }

    func handlerAdded(context: ChannelHandlerContext) {
        armHeaderTimer(context: context, seconds: HTTPRules.firstHeaderTimeout)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timer?.cancel()
    }

    private func armHeaderTimer(context: ChannelHandlerContext, seconds: Double) {
        timer?.cancel()
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: .milliseconds(Int64(seconds * 1000))) {
            loopContext.value.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !upgrading, !rejected, !overflowed else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            // A body would keep the socket open as long as the client likes:
            // answer (or just close) right away instead of waiting for it.
            if head.method != .GET || HTTPRules.hasBody(head.headers) {
                rejected = true
                if busy || !queue.isEmpty {
                    context.close(promise: nil)
                } else {
                    timer?.cancel()
                    handle(context: context, head: head)
                }
                return
            }
            current = head
        case .body:
            break
        case .end:
            // Act once the whole request was parsed, so nothing from the decoder
            // is still in flight if the pipeline changes for a WebSocket.
            guard let head = current else { return }
            current = nil
            timer?.cancel()
            if busy {
                guard queue.count < Self.maxQueued, served + queue.count < HTTPRules.maxRequestsPerSocket else {
                    overflowed = true
                    return
                }
                queue.append(head)
            } else {
                handle(context: context, head: head)
            }
        }
    }

    /// Holds socket reads while a request is being answered (backpressure).
    func read(context: ChannelHandlerContext) {
        if busy {
            pendingRead = true
        } else {
            context.read()
        }
    }

    private func resumeReading(context: ChannelHandlerContext) {
        guard pendingRead else { return }
        pendingRead = false
        context.read()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Malformed or oversized requests: close without answering.
        context.close(promise: nil)
    }

    private func handle(context: ChannelHandlerContext, head: HTTPRequestHead) {
        busy = true
        served += 1
        let config = core.config
        let identity = HTTPRules.identity(
            peerIP: peerIP, tls: tls, headers: head.headers, allowLocalProxy: config.allowLocalProxy)
        if let reply = HTTPRules.precheck(head, identity: identity, customHost: HostRules.acceptedCustomHost(config.linkHost)) {
            write(context: context, reply: reply, request: head)
            return
        }
        let (path, query) = HTTPRules.splitTarget(head.uri)
        if path == "/ws" {
            if let reply = HTTPRules.websocketCheck(head, identity: identity) {
                write(context: context, reply: reply, request: head)
            } else {
                upgrade(context: context, head: head, identity: identity)
            }
            return
        }
        let core = self.core
        let snapshot = HTTPHeadersSnapshot(ifNoneMatch: head.headers.first(name: "If-None-Match"))
        let promise = context.eventLoop.makePromise(of: HTTPReply.self)
        promise.completeWithTask {
            await core.route(path: path, query: query, headers: snapshot, identity: identity)
        }
        promise.futureResult.assumeIsolated().whenComplete { result in
            let reply = (try? result.get()) ?? .text(500, "Something went wrong.", close: true)
            self.write(context: context, reply: reply, request: head)
        }
    }

    private func write(context: ChannelHandlerContext, reply: HTTPReply, request: HTTPRequestHead) {
        // After an upgrade request the decoder stops parsing, so such sockets can't be reused.
        let keepAlive =
            !reply.forceClose && !request.headers.contains(name: "Upgrade")
            && HTTPRules.keepAlive(
                version: request.version, headers: request.headers, served: served,
                socketAge: Mono.now() - openedAt, openConnections: core.connections.openCount)
        let status = HTTPResponseStatus(statusCode: reply.status, reasonPhrase: HTTPRules.reason(reply.status))
        let head = HTTPResponseHead(
            version: request.version, status: status, headers: HTTPRules.headers(for: reply, keepAlive: keepAlive))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !reply.body.isEmpty {
            let buffer = context.channel.allocator.buffer(bytes: reply.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).assumeIsolated().whenComplete { result in
            guard keepAlive, case .success = result, !(self.overflowed && self.queue.isEmpty) else {
                context.close(promise: nil)
                return
            }
            self.busy = false
            self.armHeaderTimer(context: context, seconds: HTTPRules.nextHeaderTimeout)
            if !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                self.timer?.cancel()
                self.handle(context: context, head: next)
            } else {
                self.resumeReading(context: context)
            }
        }
    }

    private func upgrade(context: ChannelHandlerContext, head: HTTPRequestHead, identity: ClientIdentity) {
        upgrading = true
        timer?.cancel()
        let core = self.core
        let peer = PeerInfo(ip: identity.ip, secure: identity.secure)
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: Self.maxFrameSize,
            automaticErrorHandling: true,
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try core.installSession(on: channel, peer: peer)
                }
            })
        let pipeline = context.pipeline
        upgrader.buildUpgradeResponse(channel: context.channel, upgradeRequest: head, initialResponseHeaders: HTTPHeaders())
            .hop(to: context.eventLoop)
            .assumeIsolated()
            .flatMap { headers -> EventLoopFuture<Void> in
                let response = HTTPResponseHead(version: .http1_1, status: .switchingProtocols, headers: headers)
                return context.writeAndFlush(self.wrapOutboundOut(.head(response)))
            }
            .flatMap { () -> EventLoopFuture<Void> in
                // The WebSocket handlers go at the end; the HTTP decoder still holds any early
                // bytes and forwards them once it is removed last.
                upgrader.upgrade(context: context, upgradeRequest: head)
            }
            .flatMapThrowing { () -> Void in
                self.busy = false
                self.resumeReading(context: context)
                pipeline.syncOperations.removeHandler(self.encoder, promise: nil)
                pipeline.syncOperations.removeHandler(context: context, promise: nil)
                pipeline.syncOperations.removeHandler(self.decoder, promise: nil)
            }
            .whenFailure { error in
                Log.debug("http", "WebSocket upgrade failed: \(error)")
                context.close(promise: nil)
            }
    }
}
