import NIOCore
import NIOWebSocket

/// What a session's loop reacts to, in arrival order.
enum SessionEvent: Sendable {
    case text(String, bytes: Int)
    case binary([UInt8])
    /// The socket closed.
    case closed
    case tick
    case helloTimeout
    /// Mac approval: true/false from `respondApproval`, nil on timeout.
    case approval(Bool?)
    /// Host-initiated goodbye.
    case bye(reason: String, reconnect: Bool)
    case voiceUpdate(VoiceUpdate)
    case voiceBeginFailed
    /// Send a message from the session loop (keeps ordering with replies).
    case send(ServerMessage)

    /// Bytes this event holds from the socket (for read backpressure).
    var inboundBytes: Int {
        switch self {
        case .text(_, let bytes): bytes
        case .binary(let data): data.count
        default: 0
        }
    }
}

/// Pauses reading while the session loop has a lot of unprocessed input, and
/// holds the per-message size limit (small until the phone authenticates).
final class InboundFlow: Sendable {
    static let high = 4 << 20
    static let low = 1 << 20
    /// Before `welcome`: a `hello` is a few hundred bytes.
    static let unauthenticatedMessageLimit = 8 << 10
    /// After `welcome`: text is ≤ 64 KiB and settings ≤ 128 KiB, JSON-escaped.
    static let authenticatedMessageLimit = 1 << 20

    private let channel: Channel
    private let state = Locked((pending: 0, paused: false))
    private let limit = Locked(InboundFlow.unauthenticatedMessageLimit)

    init(channel: Channel) { self.channel = channel }

    var messageLimit: Int { limit.value }
    func authenticated() { limit.set(Self.authenticatedMessageLimit) }

    func added(_ bytes: Int) {
        let pause = state.withLock { s -> Bool in
            s.pending += bytes
            guard !s.paused, s.pending > Self.high else { return false }
            s.paused = true
            return true
        }
        if pause { channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in } }
    }

    func consumed(_ bytes: Int) {
        let resume = state.withLock { s -> Bool in
            s.pending = max(0, s.pending - bytes)
            guard s.paused, s.pending < Self.low else { return false }
            s.paused = false
            return true
        }
        if resume { channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in } }
    }
}

/// Turns WebSocket frames into session events: joins fragments up to the
/// current message limit (closing with 1009 above it), and answers WebSocket
/// pings and close frames itself.
final class WebSocketBridge: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let events: AsyncStream<SessionEvent>.Continuation
    private let flow: InboundFlow
    private var closing = false
    private var partial: ByteBuffer?
    private var partialOpcode: WebSocketOpcode = .text

    init(events: AsyncStream<SessionEvent>.Continuation, flow: InboundFlow) {
        self.events = events
        self.flow = flow
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closing else { return }
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            guard partial == nil else { return fail(context, code: 1002) }
            let payload = frame.unmaskedData
            guard payload.readableBytes <= flow.messageLimit else { return fail(context, code: 1009) }
            if frame.fin {
                deliver(payload, opcode: frame.opcode)
            } else {
                partial = payload
                partialOpcode = frame.opcode
            }
        case .continuation:
            guard var buffer = partial else { return fail(context, code: 1002) }
            var payload = frame.unmaskedData
            guard buffer.readableBytes + payload.readableBytes <= flow.messageLimit else {
                return fail(context, code: 1009)
            }
            buffer.writeBuffer(&payload)
            if frame.fin {
                partial = nil
                deliver(buffer, opcode: partialOpcode)
            } else {
                partial = buffer
            }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            closing = true
            var payload = frame.unmaskedData
            let code = payload.readSlice(length: min(2, payload.readableBytes)) ?? context.channel.allocator.buffer(capacity: 0)
            let reply = WebSocketFrame(fin: true, opcode: .connectionClose, data: code)
            context.writeAndFlush(wrapOutboundOut(reply)).assumeIsolated().whenComplete { _ in
                context.close(promise: nil)
            }
        default:
            break
        }
    }

    private func deliver(_ payload: ByteBuffer, opcode: WebSocketOpcode) {
        var payload = payload
        let count = payload.readableBytes
        flow.added(count)
        if opcode == .text {
            events.yield(.text(payload.readString(length: count) ?? "", bytes: count))
        } else {
            events.yield(.binary(payload.readBytes(length: count) ?? []))
        }
    }

    /// Sends a close frame with `code` (1002 protocol error, 1009 too big) and closes.
    private func fail(_ context: ChannelHandlerContext, code: UInt16) {
        closing = true
        partial = nil
        var data = context.channel.allocator.buffer(capacity: 2)
        data.writeInteger(code)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.writeAndFlush(wrapOutboundOut(frame)).assumeIsolated().whenComplete { _ in
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        partial = nil
        events.yield(.closed)
        events.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Writes JSON messages to one WebSocket. Every send has 5 s to reach the
/// socket, otherwise the connection is closed (SPEC §8.3).
final class FrameWriter: Sendable {
    static let sendTimeout: TimeAmount = .seconds(5)

    let channel: Channel

    init(channel: Channel) { self.channel = channel }

    @discardableResult
    func send(_ message: ServerMessage) -> EventLoopFuture<Void> {
        sendText(message.json.compact)
    }

    @discardableResult
    func sendText(_ text: String) -> EventLoopFuture<Void> {
        let channel = self.channel
        let promise = channel.eventLoop.makePromise(of: Void.self)
        // Always hop through the loop's queue so writes keep their order.
        channel.eventLoop.execute {
            let buffer = channel.allocator.buffer(string: text)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            let timeout = channel.eventLoop.scheduleTask(in: Self.sendTimeout) { channel.close(promise: nil) }
            let write = channel.writeAndFlush(frame)
            write.whenComplete { result in
                timeout.cancel()
                if case .failure = result { channel.close(promise: nil) }
            }
            write.cascade(to: promise)
        }
        return promise.futureResult
    }

    func close() {
        let channel = self.channel
        channel.eventLoop.execute {
            let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: channel.allocator.buffer(bytes: [0x03, 0xE8]))
            channel.writeAndFlush(frame).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
