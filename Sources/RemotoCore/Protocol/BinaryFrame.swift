import Foundation

/// A binary frame from the phone (SPEC §9.2), little-endian.
enum BinaryFrame: Equatable, Sendable {
    case move(dx: Double, dy: Double)
    case scroll(phase: UInt8, dx: Double, dy: Double)
    case fling(vx: Double, vy: Double)
    case touch
    /// PCM Int16 LE mono 16 kHz, without the type byte.
    case audio(Data)

    /// nil for frames of the wrong length, unknown type or non-finite floats.
    static func decode(_ bytes: [UInt8]) -> BinaryFrame? {
        guard let kind = bytes.first else { return nil }
        func f32(_ at: Int) -> Double? {
            let bits = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16
                | UInt32(bytes[at + 3]) << 24
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : nil
        }
        switch kind {
        case 0x01:
            guard bytes.count == 9, let dx = f32(1), let dy = f32(5) else { return nil }
            return .move(dx: dx, dy: dy)
        case 0x02:
            guard bytes.count == 10, let dx = f32(2), let dy = f32(6) else { return nil }
            return .scroll(phase: bytes[1], dx: dx, dy: dy)
        case 0x03:
            guard bytes.count == 9, let vx = f32(1), let vy = f32(5) else { return nil }
            return .fling(vx: vx, vy: vy)
        case 0x04:
            guard bytes.count == 1 else { return nil }
            return .touch
        case 0x10:
            guard bytes.count >= 3, bytes.count % 2 == 1 else { return nil }
            return .audio(Data(bytes[1...]))
        default:
            return nil
        }
    }

    /// Encoding, used by tests and tools.
    var bytes: [UInt8] {
        func le(_ v: Double) -> [UInt8] {
            let bits = Float(v).bitPattern
            return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        }
        switch self {
        case .move(let dx, let dy): return [0x01] + le(dx) + le(dy)
        case .scroll(let phase, let dx, let dy): return [0x02, phase] + le(dx) + le(dy)
        case .fling(let vx, let vy): return [0x03] + le(vx) + le(vy)
        case .touch: return [0x04]
        case .audio(let pcm): return [0x10] + [UInt8](pcm)
        }
    }
}
