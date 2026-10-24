import Foundation

/// A JSON value that keeps object key order and the literal text of numbers,
/// so messages go out with the exact field order the protocol requires and
/// values the client sent (like `ping.id`) come back unchanged.
enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number literal exactly as written (always valid JSON number syntax).
    case number(String)
    case string(String)
    case array([JSON])
    case object([Member])

    struct Member: Equatable, Sendable {
        var key: String
        var value: JSON
        init(_ key: String, _ value: JSON) {
            self.key = key
            self.value = value
        }
    }
}

// MARK: - Building

extension JSON {
    static func int<T: BinaryInteger>(_ value: T) -> JSON { .number(String(value)) }

    static func float(_ value: Float) -> JSON {
        guard value.isFinite else { return .number("0") }
        if value == value.rounded(), abs(value) < 1e7 { return .number(String(Int(value))) }
        return .number(value.description)
    }

    static func obj(_ members: [(String, JSON?)]) -> JSON {
        .object(members.compactMap { key, value in value.map { Member(key, $0) } })
    }

    static func optString(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }
}

// MARK: - Reading

extension JSON {
    subscript(key: String) -> JSON? {
        guard case .object(let members) = self else { return nil }
        return members.last(where: { $0.key == key })?.value
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var arrayValue: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// The number as an unsigned integer, if it is a plain integer literal that fits.
    func unsigned<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) -> T? {
        guard case .number(let text) = self else { return nil }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return T(text)
    }

    var doubleValue: Double? {
        guard case .number(let text) = self else { return nil }
        return Double(text)
    }
}

// MARK: - Serializing

extension JSON {
    /// Compact form (no whitespace).
    var compact: String {
        var out = ""
        write(into: &out, indent: nil, level: 0)
        return out
    }

    /// Pretty form with two-space indentation and a trailing newline, used for files.
    var pretty: String {
        var out = ""
        write(into: &out, indent: "  ", level: 0)
        out.append("\n")
        return out
    }

    var compactData: Data { Data(compact.utf8) }

    private func write(into out: inout String, indent: String?, level: Int) {
        switch self {
        case .null: out.append("null")
        case .bool(let b): out.append(b ? "true" : "false")
        case .number(let n): out.append(n)
        case .string(let s): JSON.writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty {
                out.append("[]")
                return
            }
            out.append("[")
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(",") }
                JSON.newline(&out, indent, level + 1)
                item.write(into: &out, indent: indent, level: level + 1)
            }
            JSON.newline(&out, indent, level)
            out.append("]")
        case .object(let members):
            if members.isEmpty {
                out.append("{}")
                return
            }
            out.append("{")
            for (i, member) in members.enumerated() {
                if i > 0 { out.append(",") }
                JSON.newline(&out, indent, level + 1)
                JSON.writeString(member.key, into: &out)
                out.append(indent == nil ? ":" : ": ")
                member.value.write(into: &out, indent: indent, level: level + 1)
            }
            JSON.newline(&out, indent, level)
            out.append("}")
        }
    }

    private static func newline(_ out: inout String, _ indent: String?, _ level: Int) {
        guard let indent else { return }
        out.append("\n")
        for _ in 0..<level { out.append(indent) }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out.append("\"")
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
    }
}

// MARK: - Parsing

struct JSONParseError: Error, Equatable {
    var offset: Int
}

extension JSON {
    static let maxDepth = 256

    static func parse(_ text: String) throws(JSONParseError) -> JSON {
        try parse(Array(text.utf8))
    }

    static func parse(_ data: Data) throws(JSONParseError) -> JSON {
        try parse([UInt8](data))
    }

    static func parse(_ bytes: [UInt8]) throws(JSONParseError) -> JSON {
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw JSONParseError(offset: parser.index) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        func fail() -> JSONParseError { JSONParseError(offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func expect(_ literal: String) throws(JSONParseError) {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw fail() }
                index += 1
            }
        }

        mutating func value(depth: Int) throws(JSONParseError) -> JSON {
            guard depth < JSON.maxDepth, index < bytes.count else { throw fail() }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws(JSONParseError) -> JSON {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail() }
                let key = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                let item = try value(depth: depth + 1)
                members.append(Member(key, item))
                skipWhitespace()
                guard index < bytes.count else { throw fail() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "}") {
                    index += 1
                    return .object(members)
                }
                throw fail()
            }
        }

        mutating func array(depth: Int) throws(JSONParseError) -> JSON {
            index += 1
            var items: [JSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw fail() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                if bytes[index] == UInt8(ascii: "]") {
                    index += 1
                    return .array(items)
                }
                throw fail()
            }
        }

        mutating func number() throws(JSONParseError) -> String {
            let start = index
            func digit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, digit(bytes[index]) else { throw fail() }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, digit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, digit(bytes[index]) else { throw fail() }
                while index < bytes.count, digit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                    index += 1
                }
                guard index < bytes.count, digit(bytes[index]) else { throw fail() }
                while index < bytes.count, digit(bytes[index]) { index += 1 }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func hex4() throws(JSONParseError) -> UInt32 {
            guard index + 4 <= bytes.count else { throw fail() }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let b = bytes[index]
                let nibble: UInt32
                switch b {
                case 0x30...0x39: nibble = UInt32(b - 0x30)
                case 0x41...0x46: nibble = UInt32(b - 0x41 + 10)
                case 0x61...0x66: nibble = UInt32(b - 0x61 + 10)
                default: throw fail()
                }
                value = value << 4 | nibble
                index += 1
            }
            return value
        }

        mutating func string() throws(JSONParseError) -> String {
            index += 1
            var out = [UInt8]()
            while true {
                guard index < bytes.count else { throw fail() }
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    index += 1
                    break
                }
                if b < 0x20 { throw fail() }
                if b != UInt8(ascii: "\\") {
                    out.append(b)
                    index += 1
                    continue
                }
                index += 1
                guard index < bytes.count else { throw fail() }
                let esc = bytes[index]
                index += 1
                switch esc {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if code >= 0xD800 && code < 0xDC00 {
                        // High surrogate: a low surrogate must follow.
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                            bytes[index + 1] == UInt8(ascii: "u")
                        else { throw fail() }
                        index += 2
                        let low = try hex4()
                        guard low >= 0xDC00 && low < 0xE000 else { throw fail() }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if code >= 0xDC00 && code < 0xE000 {
                        throw fail()
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw fail() }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw fail()
                }
            }
            // Reject invalid UTF-8 instead of silently repairing it.
            guard let text = String(bytes: out, encoding: .utf8) else { throw fail() }
            return text
        }
    }
}
