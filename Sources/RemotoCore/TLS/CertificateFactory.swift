import Crypto
import Foundation
import SwiftASN1
import X509

/// Creates the local CA and the server certificate (SPEC §5.2, §5.3).
enum CertificateFactory {
    static let day: TimeInterval = 86_400
    static let caLifetimeDays: Double = 3650
    static let leafLifetimeDays: Double = 397

    struct Issued {
        var key: P256.Signing.PrivateKey
        var certificate: Certificate
        var der: [UInt8]
        var notAfter: Date
    }

    static func serialize(_ certificate: Certificate) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return serializer.serializedBytes
    }

    /// The SPEC's 8 permitted subtrees, plus excluded subtrees for every IPv6
    /// address and for URI names, so the CA can only ever vouch for LAN server
    /// names (see docs/CONFORMANCE.md, item 11). No rfc822Name exclusion: some
    /// verifiers (swift-certificates among them) reject any chain whose CA
    /// constrains e-mail names, which would break HTTPS on those clients.
    static func nameConstraints() -> NameConstraints {
        let ranges = ServerNames.permittedIPv4.map { network, prefix -> GeneralName in
            let mask: UInt32 = ~UInt32(0) << (32 - prefix)
            let maskBytes = [UInt8(mask >> 24), UInt8(mask >> 16 & 0xFF), UInt8(mask >> 8 & 0xFF), UInt8(mask & 0xFF)]
            return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(network + maskBytes)))
        }
        let permitted = ServerNames.permittedDNS.map { GeneralName.dnsName($0) } + ranges
        let excluded: [GeneralName] = [
            .ipAddress(ASN1OctetString(contentBytes: ArraySlice(repeating: 0, count: 32))),
            .uniformResourceIdentifier(""),
        ]
        return NameConstraints(permittedSubtrees: permitted, excludedSubtrees: excluded)
    }

    static func makeCA(now: Date = Date()) throws -> Issued {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName("Remoto Local CA " + Secrets.randomToken(3))
            OrganizationName("Remoto")
        }
        let publicKey = Certificate.PublicKey(key.publicKey)
        let notAfter = now.addingTimeInterval(caLifetimeDays * day)
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true))
            Critical(nameConstraints())
            SubjectKeyIdentifier(hash: publicKey)
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-day), notValidAfter: notAfter,
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256, extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(key))
        return Issued(key: key, certificate: certificate, der: try serialize(certificate), notAfter: notAfter)
    }

    static func makeLeaf(
        names: [String], caKey: P256.Signing.PrivateKey, caCertificate: Certificate, caNotAfter: Date,
        now: Date = Date()
    ) throws -> Issued {
        let key = P256.Signing.PrivateKey()
        let commonName = names.first { $0.hasSuffix(".local") } ?? "Remoto"
        let subject = try DistinguishedName { CommonName(commonName) }
        let publicKey = Certificate.PublicKey(key.publicKey)
        let notAfter = min(now.addingTimeInterval(leafLifetimeDays * day), caNotAfter)
        let sans: [GeneralName] = names.map { name in
            if let bytes = Addresses.ipv4Bytes(name) {
                return .ipAddress(ASN1OctetString(contentBytes: ArraySlice(bytes)))
            }
            return .dnsName(name)
        }
        let caKeyID = try caCertificate.extensions.subjectKeyIdentifier?.keyIdentifier
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames(sans)
            SubjectKeyIdentifier(hash: publicKey)
            if let caKeyID {
                AuthorityKeyIdentifier(keyIdentifier: caKeyID)
            }
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-day), notValidAfter: notAfter,
            issuer: caCertificate.subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions, issuerPrivateKey: Certificate.PrivateKey(caKey))
        return Issued(key: key, certificate: certificate, der: try serialize(certificate), notAfter: notAfter)
    }

    /// SHA-256 of the DER, uppercase hex pairs joined by `:` (SPEC §5.5).
    static func fingerprint(_ der: [UInt8]) -> String {
        SHA256.hash(data: Data(der)).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
