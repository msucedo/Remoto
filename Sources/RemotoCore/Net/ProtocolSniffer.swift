import NIOCore
import NIOHTTP1
import NIOSSL

/// Looks at the first byte of a connection: `0x16` is a TLS ClientHello and
/// gets a TLS handler; anything else is plain HTTP (SPEC §4.3).
final class ProtocolSniffer: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    static let peekTimeout: TimeAmount = .seconds(10)
    static let handshakeTimeout: TimeAmount = .seconds(10)

    private let core: HostCore
    private let peerIP: String
    private var timer: Scheduled<Void>?
    private var decided = false

    init(core: HostCore, peerIP: String) {
        self.core = core
        self.peerIP = peerIP
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: Self.peekTimeout) { loopContext.value.close(promise: nil) }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timer?.cancel()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !decided else {
            context.fireChannelRead(data)
            return
        }
        let buffer = unwrapInboundIn(data)
        guard let first = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else { return }
        decided = true
        timer?.cancel()
        do {
            let sync = context.pipeline.syncOperations
            if first == 0x16 {
                guard let tls = core.tlsContext else {
                    // No identity: close without an alert or a log line.
                    context.close(promise: nil)
                    return
                }
                let watcher = HandshakeWatcher()
                let http = HTTPPipeline.handlers(core: core, peerIP: peerIP, tls: true)
                try sync.addHandlers([NIOSSLServerHandler(context: tls), watcher] + http, position: .after(self))
            } else {
                let http = HTTPPipeline.handlers(core: core, peerIP: peerIP, tls: false)
                try sync.addHandlers(http, position: .after(self))
            }
        } catch {
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}

/// Closes connections whose TLS handshake (and first request bytes) don't arrive in time.
final class HandshakeWatcher: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    private var timer: Scheduled<Void>?

    func handlerAdded(context: ChannelHandlerContext) {
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: ProtocolSniffer.handshakeTimeout) {
            loopContext.value.close(promise: nil)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        timer?.cancel()
    }

    /// The first decrypted bytes mean the handshake is done.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        timer?.cancel()
        context.fireChannelRead(data)
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Handshake failures end the connection quietly.
        context.close(promise: nil)
    }
}

enum HTTPPipeline {
    static func handlers(core: HostCore, peerIP: String, tls: Bool) -> [ChannelHandler] {
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = HTTPRules.maxHeaderBytes
        limits.maxHeaderListSize = HTTPRules.maxHeaderBytes
        let decoder = ByteToMessageHandler(
            HTTPRequestDecoder(
                leftOverBytesStrategy: .forwardBytes, informationalResponseStrategy: .drop, limitConfiguration: limits))
        var encoderConfig = HTTPResponseEncoder.Configuration()
        encoderConfig.automaticallySetFramingHeaders = false
        let encoder = HTTPResponseEncoder(configuration: encoderConfig)
        let handler = HTTPHandler(core: core, peerIP: peerIP, tls: tls, decoder: decoder, encoder: encoder)
        return [decoder, encoder, handler]
    }
}
