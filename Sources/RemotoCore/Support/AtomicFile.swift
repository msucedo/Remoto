import Darwin
import Foundation

/// Private, atomic file writes (SPEC §7.5): temp file in the same folder, `fsync`,
/// then `rename`. Files are `0600`; folders the core creates are `0700`.
enum AtomicFile {
    struct IOError: Error, CustomStringConvertible {
        var description: String
    }

    static func ensureDirectory(_ url: URL) throws {
        let path = url.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw IOError(description: "\(path) is not a folder") }
            chmod(path, 0o700)
            return
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(path, 0o700)
    }

    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(Secrets.randomToken(6)).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IOError(description: "open \(tmp.path): \(String(cString: strerror(errno)))") }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        let wrote = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard wrote, synced else { throw IOError(description: "write \(tmp.path) failed") }
        guard rename(tmp.path, url.path) == 0 else {
            throw IOError(description: "rename to \(url.path): \(String(cString: strerror(errno)))")
        }
        ok = true
        syncDirectory(dir)
    }

    /// Makes the rename itself durable.
    private static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Moves an unreadable file aside as `<name>.corrupt`.
    static func quarantine(_ url: URL) {
        let target = url.appendingPathExtension("corrupt")
        unlink(target.path)
        rename(url.path, target.path)
    }

    static func remove(_ url: URL) {
        unlink(url.path)
    }
}
