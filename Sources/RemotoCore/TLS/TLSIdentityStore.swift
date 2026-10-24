import Crypto
import Foundation
import NIOSSL
import X509

/// A loaded TLS identity: what HTTPS and `/remoto.crt` need.
struct TLSIdentity: Sendable {
    var caDER: [UInt8]
    var caFingerprint: String
    var leafNames: [String]
    var context: NIOSSLContext
    /// The earlier of the CA's and the leaf's expiry.
    var expires: Date

    /// True once a renewal is due (inside the 30-day margin).
    func needsRenewal(now: Date = Date()) -> Bool {
        expires <= now.addingTimeInterval(TLSIdentityStore.renewMargin)
    }
}

/// What happened during a load, for logs and tests.
struct TLSLoadReport: Equatable, Sendable {
    var newCA: Bool
    var newLeaf: Bool
}

/// Files in `dataDir` (SPEC §5.1) and the keep-or-renew rules (SPEC §5.4).
enum TLSIdentityStore {
    static let renewMargin: TimeInterval = 30 * 86_400

    struct Paths {
        let identity, caKey, caCert, leafKey, leafCert: URL
        init(dataDir: URL) {
            identity = dataDir.appendingPathComponent("identity.json")
            caKey = dataDir.appendingPathComponent("ca.key.pem")
            caCert = dataDir.appendingPathComponent("ca.cert.der")
            leafKey = dataDir.appendingPathComponent("leaf.key.pem")
            leafCert = dataDir.appendingPathComponent("leaf.cert.der")
        }
    }

    struct Meta: Equatable {
        var caName: String
        var caExpires: Int64
        var leafNames: [String]
        var leafExpires: Int64

        var json: JSON {
            .obj([
                ("caName", .string(caName)), ("caExpires", .int(caExpires)),
                ("leafNames", .array(leafNames.map(JSON.string))), ("leafExpires", .int(leafExpires)),
            ])
        }

        init(caName: String, caExpires: Int64, leafNames: [String], leafExpires: Int64) {
            self.caName = caName
            self.caExpires = caExpires
            self.leafNames = leafNames
            self.leafExpires = leafExpires
        }

        init?(data: Data) {
            guard let root = try? JSON.parse(data), let caName = root["caName"]?.stringValue,
                let caExpires = root["caExpires"]?.doubleValue, let names = root["leafNames"]?.arrayValue,
                let leafExpires = root["leafExpires"]?.doubleValue
            else { return nil }
            let leafNames = names.compactMap(\.stringValue)
            guard leafNames.count == names.count else { return nil }
            self.init(caName: caName, caExpires: Int64(caExpires), leafNames: leafNames, leafExpires: Int64(leafExpires))
        }
    }

    private static func readKey(_ url: URL) -> P256.Signing.PrivateKey? {
        guard let data = AtomicFile.read(url) else { return nil }
        return try? P256.Signing.PrivateKey(pemRepresentation: String(decoding: data, as: UTF8.self))
    }

    private static func readCertificate(_ url: URL, matching key: P256.Signing.PrivateKey) -> Certificate? {
        guard let data = AtomicFile.read(url), let cert = try? Certificate(derEncoded: [UInt8](data)) else {
            return nil
        }
        // A certificate whose key file was replaced or lost is useless.
        guard cert.publicKey == Certificate.PublicKey(key.publicKey) else { return nil }
        return cert
    }

    /// Loads, keeps or renews the identity for `names` and writes what changed.
    static func load(dataDir: URL, names: [String], now: Date = Date()) throws -> (TLSIdentity, TLSLoadReport) {
        let paths = Paths(dataDir: dataDir)
        try AtomicFile.ensureDirectory(dataDir)
        let threshold = Int64(now.addingTimeInterval(renewMargin).timeIntervalSince1970)
        let meta = AtomicFile.read(paths.identity).flatMap(Meta.init(data:))

        // CA: keep only if key, certificate and metadata are all good and not close to expiry.
        var caKey: P256.Signing.PrivateKey
        var caCert: Certificate
        var caDER: [UInt8]
        var caNotAfter: Date
        var newCA = false
        if let meta, meta.caExpires > threshold, let key = readKey(paths.caKey),
            let cert = readCertificate(paths.caCert, matching: key)
        {
            caKey = key
            caCert = cert
            caDER = try CertificateFactory.serialize(cert)
            caNotAfter = cert.notValidAfter
        } else {
            let ca = try CertificateFactory.makeCA(now: now)
            try AtomicFile.write(Data(ca.key.pemRepresentation.utf8), to: paths.caKey)
            try AtomicFile.write(Data(ca.der), to: paths.caCert)
            caKey = ca.key
            caCert = ca.certificate
            caDER = ca.der
            caNotAfter = ca.notAfter
            newCA = true
        }

        // Leaf: keep only with the same names in the same order, same CA, and time left.
        var leafKey: P256.Signing.PrivateKey
        var leafDER: [UInt8]
        var leafNotAfter: Date
        var newLeaf = false
        if !newCA, let meta, meta.leafNames == names, meta.leafExpires > threshold,
            let key = readKey(paths.leafKey), let cert = readCertificate(paths.leafCert, matching: key),
            cert.issuer == caCert.subject
        {
            leafKey = key
            leafDER = try CertificateFactory.serialize(cert)
            leafNotAfter = cert.notValidAfter
        } else {
            let leaf = try CertificateFactory.makeLeaf(
                names: names, caKey: caKey, caCertificate: caCert, caNotAfter: caNotAfter, now: now)
            try AtomicFile.write(Data(leaf.key.pemRepresentation.utf8), to: paths.leafKey)
            try AtomicFile.write(Data(leaf.der), to: paths.leafCert)
            leafKey = leaf.key
            leafDER = leaf.der
            leafNotAfter = leaf.notAfter
            newLeaf = true
        }

        let newMeta = Meta(
            caName: caCert.subject.description, caExpires: Int64(caNotAfter.timeIntervalSince1970),
            leafNames: names, leafExpires: Int64(leafNotAfter.timeIntervalSince1970))
        if newMeta != meta {
            try AtomicFile.write(newMeta.json.pretty, to: paths.identity)
        }

        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: leafDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leafKey.pemRepresentation.utf8), format: .pem)))
        tls.applicationProtocols = ["http/1.1"]
        tls.minimumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: tls)
        let identity = TLSIdentity(
            caDER: caDER, caFingerprint: CertificateFactory.fingerprint(caDER), leafNames: names, context: context,
            expires: min(caNotAfter, leafNotAfter))
        return (identity, TLSLoadReport(newCA: newCA, newLeaf: newLeaf))
    }
}
