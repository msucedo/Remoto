import Darwin
import Foundation

/// Serves the web client from `webRoot` (SPEC §4.7, "Estáticos").
enum StaticFiles {
    static let placeholder = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Remoto</title></head>
        <body style="font-family: -apple-system, system-ui, sans-serif; max-width: 32rem; margin: 3rem auto; padding: 0 1rem">
        <h1>Remoto is running</h1>
        <p>This copy of Remoto was built without its web client, so there is nothing to show on the phone yet.
        Build the web client and point the app at it, then reload this page.</p>
        </body></html>
        """

    struct FileInfo {
        var path: String
        var size: Int
        var mtimeNanos: UInt64
        var isDirectory: Bool
    }

    static func info(_ path: String) -> FileInfo? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let nanos = UInt64(max(0, st.st_mtimespec.tv_sec)) * 1_000_000_000 + UInt64(max(0, st.st_mtimespec.tv_nsec))
        return FileInfo(
            path: path, size: Int(st.st_size), mtimeNanos: nanos, isDirectory: (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// Decoded path segments, or nil when any segment is not allowed.
    static func segments(_ path: String) -> [String]? {
        var out: [String] = []
        for raw in path.split(separator: "/") {
            guard let seg = HTTPRules.percentDecode(raw) else { return nil }
            if seg.hasPrefix(".") || seg.contains("\\") || seg.contains("\0") || seg.contains("/") { return nil }
            out.append(seg)
        }
        return out
    }

    static func reply(path: String, ifNoneMatch: String?, webRoot: URL?) -> HTTPReply {
        guard let webRoot, let rootInfo = info(webRoot.path), rootInfo.isDirectory else {
            return HTTPReply(
                status: 200, contentType: "text/html; charset=utf-8", body: Array(placeholder.utf8),
                extraHeaders: [("Cache-Control", "no-cache")])
        }
        guard let segs = segments(path) else { return .text(404, "Not found.") }
        let rootPath = webRoot.resolvingSymlinksInPath().path
        var target = segs.reduce(rootPath) { $0 + "/" + $1 }
        var immutable = segs.first == "assets"
        var found = info(target)
        if found?.isDirectory == true {
            target += "/index.html"
            found = info(target)
        }
        if found == nil || found?.isDirectory == true {
            let last = segs.last ?? ""
            guard !last.contains(".") else { return .text(404, "Not found.") }
            // SPA fallback.
            target = rootPath + "/index.html"
            found = info(target)
            immutable = false
            guard found != nil else {
                return HTTPReply(
                    status: 200, contentType: "text/html; charset=utf-8", body: Array(placeholder.utf8),
                    extraHeaders: [("Cache-Control", "no-cache")])
            }
        }
        guard let file = found else { return .text(404, "Not found.") }
        // Never serve something a symlink points to outside the web root.
        let real = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
        guard real == rootPath || real.hasPrefix(rootPath + "/") else { return .text(404, "Not found.") }

        let ext = (target as NSString).pathExtension
        let etag = HTTPRules.etag(length: file.size, mtimeNanos: file.mtimeNanos)
        var extra: [(String, String)] = [
            ("Cache-Control", immutable ? "public, max-age=31536000, immutable" : "no-cache"), ("ETag", etag),
        ]
        if (target as NSString).lastPathComponent == "sw.js" { extra.append(("Service-Worker-Allowed", "/")) }
        let type = HTTPRules.contentType(forExtension: ext)
        if let ifNoneMatch, ifNoneMatch.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == etag }) {
            return HTTPReply(status: 304, contentType: type, body: [], extraHeaders: extra, contentLength: file.size)
        }
        guard let data = FileManager.default.contents(atPath: target) else { return .text(404, "Not found.") }
        return HTTPReply(status: 200, contentType: type, body: [UInt8](data), extraHeaders: extra)
    }
}
