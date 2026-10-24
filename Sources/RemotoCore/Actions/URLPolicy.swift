/// Which links a deck tile may open (SPEC §13.2, `url`). This is a block
/// list on purpose: third-party apps register their own schemes.
enum URLPolicy {
    static let notAllowed = "That kind of link isn't allowed."
    /// Schemes that run code in the page or that mount network shares and
    /// servers without asking. Blocked always.
    static let alwaysBlocked: Set<String> = ["javascript", "data", "smb", "afp", "nfs", "cifs", "ftp", "ftps"]

    /// nil when the link may be opened, otherwise a message for people.
    static func check(_ url: String, allowShell: Bool) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return notAllowed }
        let scheme = url[..<colon]
        let valid = !scheme.isEmpty && scheme.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b == UInt8(ascii: "+") || b == UInt8(ascii: ".") || b == UInt8(ascii: "-")
        }
        guard valid else { return notAllowed }
        let lower = scheme.lowercased()
        if alwaysBlocked.contains(lower) { return notAllowed }
        if lower == "file" { return allowShell ? nil : notAllowed }
        return nil
    }
}
