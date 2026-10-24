import Darwin
import Foundation
import Testing
@testable import RemotoCore

@Suite struct ActionTests {
    @Test func urlPolicy() {
        #expect(URLPolicy.check("javascript:alert(1)", allowShell: true) != nil)
        #expect(URLPolicy.check("JavaScript:alert(1)", allowShell: true) != nil)
        #expect(URLPolicy.check("data:text/html,x", allowShell: true) != nil)
        #expect(URLPolicy.check("file:///tmp", allowShell: false) != nil)
        #expect(URLPolicy.check("file:///tmp", allowShell: true) == nil)
        #expect(URLPolicy.check("https://example.com", allowShell: false) == nil)
        #expect(URLPolicy.check("x-apple.systempreferences:com.apple", allowShell: false) == nil)
        #expect(URLPolicy.check("bad scheme:x", allowShell: false) != nil)
        #expect(URLPolicy.check(":nothing", allowShell: false) != nil)
        for scheme in ["smb", "SMB", "afp", "nfs", "cifs", "ftp", "ftps"] {
            #expect(URLPolicy.check("\(scheme)://server/share", allowShell: true) != nil, "\(scheme)")
        }
        #expect(URLPolicy.check("obsidian://open?vault=x", allowShell: false) == nil)
        #expect(URLPolicy.check("sftp://host", allowShell: false) == nil)
    }

    @Test func systemTable() {
        #expect(SystemActions.step(for: .spotlight) == .tap(code: 0x31, mods: Mods.cmd))
        #expect(SystemActions.step(for: .copy) == .letter("c", code: 0x08, mods: Mods.cmd))
        #expect(SystemActions.step(for: .redo) == .letter("z", code: 0x06, mods: Mods.cmd | Mods.shift))
        #expect(SystemActions.step(for: .fullscreen) == .letter("f", code: 0x03, mods: Mods.control | Mods.cmd))
        #expect(SystemActions.step(for: .emojiPicker) == .tap(code: 0x31, mods: Mods.control | Mods.cmd))
        #expect(SystemActions.step(for: .previousTab) == .tap(code: 0x30, mods: Mods.control | Mods.shift))
        #expect(SystemActions.step(for: .lockScreen) == .native(.lockScreen))
        #expect(SystemActions.step(for: .showDesktop) == .tap(code: 0x67, mods: 0))
        for action in SystemAction.allCases {
            if case .letter(let c, let code, _) = SystemActions.step(for: action) {
                #expect(SystemActions.ansi[String(c)] == code)
            }
        }
    }

    @Test func shellRunsInItsOwnGroupAndIsKilledOnStop() async throws {
        let stop = Locked(false)
        let marker = makeTempDir().appendingPathComponent("started")
        // Ignores SIGTERM, so SIGKILL is what ends it.
        let pid = try ShellRunner.launch("trap '' TERM; touch '\(marker.path)'; sleep 30", shouldStop: { stop.value })
        #expect(getpgid(pid) == pid)
        #expect(await eventually { FileManager.default.fileExists(atPath: marker.path) })
        stop.set(true)
        let gone = await eventually(timeout: .seconds(4)) { kill(-pid, 0) != 0 }
        #expect(gone)
    }
}
