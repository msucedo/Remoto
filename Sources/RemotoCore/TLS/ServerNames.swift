/// The names the server certificate covers (SPEC §5.4), limited to what the
/// CA's name constraints allow.
enum ServerNames {
    /// Permitted IPv4 subtrees as (network, prefix length) (SPEC §5.2).
    static let permittedIPv4: [(network: [UInt8], prefix: Int)] = [
        ([10, 0, 0, 0], 8), ([172, 16, 0, 0], 12), ([192, 168, 0, 0], 16),
        ([100, 64, 0, 0], 10), ([169, 254, 0, 0], 16), ([127, 0, 0, 0], 8),
    ]
    static let permittedDNS = ["local", "localhost"]

    static func isPermittedIPv4(_ ip: String) -> Bool {
        guard let bytes = Addresses.ipv4Bytes(ip) else { return false }
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return permittedIPv4.contains { net, prefix in
            let n = UInt32(net[0]) << 24 | UInt32(net[1]) << 16 | UInt32(net[2]) << 8 | UInt32(net[3])
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
            return value & mask == n & mask
        }
    }

    static func isPermittedDNS(_ name: String) -> Bool {
        guard !name.isEmpty, !HostRules.isIPv4(name), !name.contains(":") else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy(HostRules.isLabel) else { return false }
        return permittedDNS.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    static func compute(hostName: String, addresses: [String]) -> [String] {
        var host = Substring(hostName.trimmingCharacters(in: .whitespaces))
        while host.hasSuffix(".") { host = host.dropLast() }
        let candidates = ["localhost", "127.0.0.1", host.lowercased()] + addresses
        let allowed = candidates.filter { HostRules.isIPv4($0) ? isPermittedIPv4($0) : isPermittedDNS($0) }
        return Array(Set(allowed)).sorted()
    }
}

import Foundation
