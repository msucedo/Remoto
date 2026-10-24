import Crypto
import Foundation
import SwiftASN1
import Testing
import X509
@testable import RemotoCore

@Suite struct TLSTests {
    let names = ServerNames.compute(hostName: "Studio.local.", addresses: ["192.168.1.20", "8.8.8.8"])

    func certificate(_ dir: URL, _ file: String) throws -> Certificate {
        try Certificate(derEncoded: [UInt8](Data(contentsOf: dir.appendingPathComponent(file))))
    }

    @Test func serverNamesAreFilteredSortedUnique() {
        #expect(names == ["127.0.0.1", "192.168.1.20", "localhost", "studio.local"])
        let more = ServerNames.compute(
            hostName: "box.example.com", addresses: ["10.1.2.3", "100.64.0.1", "172.32.0.1", "10.1.2.3", "fe80::1"])
        #expect(more == ["10.1.2.3", "100.64.0.1", "127.0.0.1", "localhost"])
    }

    @Test func createsCAWithConstraintsAndLeafWithSAN() throws {
        let dir = makeTempDir()
        let (identity, report) = try TLSIdentityStore.load(dataDir: dir, names: names)
        #expect(report == TLSLoadReport(newCA: true, newLeaf: true))
        #expect(identity.caFingerprint.count == 95)
        #expect(identity.caFingerprint.split(separator: ":").allSatisfy { $0.count == 2 && $0.uppercased() == $0 })

        let ca = try certificate(dir, "ca.cert.der")
        #expect(ca.subject.description.contains("CN=Remoto Local CA "))
        #expect(ca.subject.description.contains("O=Remoto"))
        let constraints = try #require(try ca.extensions.nameConstraints)
        #expect(constraints.permittedSubtrees.count == 8)
        // Deviation from the SPEC for safety: all IPv6 and URI names excluded.
        #expect(constraints.excludedSubtrees.count == 2)
        #expect(constraints.excludedSubtrees.contains(.ipAddress(ASN1OctetString(contentBytes: ArraySlice(repeating: 0, count: 32)))))
        #expect(constraints.excludedSubtrees.contains(.uniformResourceIdentifier("")))
        #expect(Set(constraints.permittedDNSDomains) == ["local", "localhost"])
        #expect(try ca.extensions.basicConstraints == .isCertificateAuthority(maxPathLength: 0))
        let caDays = ca.notValidAfter.timeIntervalSince(ca.notValidBefore) / 86_400
        #expect(abs(caDays - 3651) < 0.01)

        let leaf = try certificate(dir, "leaf.cert.der")
        #expect(leaf.issuer == ca.subject)
        #expect(leaf.subject.description == "CN=studio.local")
        #expect(leaf.notValidAfter <= ca.notValidAfter)
        let leafDays = leaf.notValidAfter.timeIntervalSince(leaf.notValidBefore) / 86_400
        #expect(leafDays <= 398.01)
        let sans = try #require(try leaf.extensions.subjectAlternativeNames)
        var dns: [String] = []
        var ips: [[UInt8]] = []
        for name in sans {
            switch name {
            case .dnsName(let d): dns.append(d)
            case .ipAddress(let bytes): ips.append(Array(bytes.bytes))
            default: Issue.record("unexpected SAN \(name)")
            }
        }
        #expect(dns == ["localhost", "studio.local"])
        #expect(ips == [[127, 0, 0, 1], [192, 168, 1, 20]])
        #expect(try leaf.extensions.extendedKeyUsage?.contains(.serverAuth) == true)
        // The leaf is signed by the CA key.
        #expect(ca.publicKey.isValidSignature(leaf.signature, for: leaf))

        for file in ["ca.key.pem", "leaf.key.pem", "identity.json"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)
            #expect((attrs[.posixPermissions] as? Int) == 0o600, "\(file)")
        }
        let meta = try JSON.parse(Data(contentsOf: dir.appendingPathComponent("identity.json")))
        #expect(meta["leafNames"] == .array(names.map(JSON.string)))
    }

    @Test func reusesThenRenewsOnlyWhatChanged() throws {
        let dir = makeTempDir()
        let (first, _) = try TLSIdentityStore.load(dataDir: dir, names: names)
        let (same, sameReport) = try TLSIdentityStore.load(dataDir: dir, names: names)
        #expect(sameReport == TLSLoadReport(newCA: false, newLeaf: false))
        #expect(same.caDER == first.caDER)

        var moved = names
        moved[1] = "192.168.1.21"
        let (renamed, renamedReport) = try TLSIdentityStore.load(dataDir: dir, names: moved.sorted())
        #expect(renamedReport == TLSLoadReport(newCA: false, newLeaf: true))
        #expect(renamed.caDER == first.caDER)
    }

    @Test func caNearExpiryIsReplaced() throws {
        let dir = makeTempDir()
        let past = Date().addingTimeInterval(-3630 * 86_400)
        let (old, _) = try TLSIdentityStore.load(dataDir: dir, names: names, now: past)
        let (fresh, report) = try TLSIdentityStore.load(dataDir: dir, names: names)
        #expect(report == TLSLoadReport(newCA: true, newLeaf: true))
        #expect(fresh.caDER != old.caDER)
    }

    @Test func missingKeyRegenerates() throws {
        let dir = makeTempDir()
        let (first, _) = try TLSIdentityStore.load(dataDir: dir, names: names)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("ca.key.pem"))
        let (second, report) = try TLSIdentityStore.load(dataDir: dir, names: names)
        #expect(report.newCA && report.newLeaf)
        #expect(second.caDER != first.caDER)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("leaf.key.pem"))
        let (_, leafOnly) = try TLSIdentityStore.load(dataDir: dir, names: names)
        #expect(leafOnly == TLSLoadReport(newCA: false, newLeaf: true))
    }

    @Test func fingerprintFormat() {
        let fp = CertificateFactory.fingerprint([1, 2, 3])
        #expect(fp == "03:90:58:C6:F2:C0:CB:49:2C:53:3B:0A:4D:14:EF:77:CC:0F:78:AB:CC:CE:D5:28:7D:84:A1:A2:01:1C:FB:81")
    }
}
