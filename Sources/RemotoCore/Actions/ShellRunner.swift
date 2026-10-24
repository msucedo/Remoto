import Darwin
import Foundation

/// Fire-and-forget `shell` actions (SPEC §13.2): `/bin/zsh -lc <command>` in
/// its own process group, I/O to `/dev/null`. A watcher ends the group with
/// SIGTERM, then SIGKILL, when control is paused or the phone goes away.
enum ShellRunner {
    struct LaunchError: Error, CustomStringConvertible {
        var description: String
    }

    static let pollInterval: Duration = .milliseconds(100)
    static let killGrace: Double = 1

    /// Starts the command and returns its pid (also its process group id).
    @discardableResult
    static func launch(_ command: String, shouldStop: @escaping @Sendable () -> Bool) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Children shouldn't inherit a blocked signal mask from our threads.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        let argv = ["/bin/zsh", "-lc", command]
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgs { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &cArgs, environ)
        guard rc == 0 else { throw LaunchError(description: String(cString: strerror(rc))) }
        watch(pid: pid, shouldStop: shouldStop)
        return pid
    }

    private static func watch(pid: pid_t, shouldStop: @escaping @Sendable () -> Bool) {
        Task.detached(priority: .utility) {
            var leaderReaped = false
            var termSentAt: Double?
            while true {
                if !leaderReaped {
                    var status: Int32 = 0
                    let r = waitpid(pid, &status, WNOHANG)
                    if r == pid || (r < 0 && errno == ECHILD) { leaderReaped = true }
                }
                // The group lives on while any member is alive.
                let groupAlive = kill(-pid, 0) == 0 || errno == EPERM
                if leaderReaped && !groupAlive { return }
                if let sent = termSentAt {
                    if Mono.now() - sent >= killGrace {
                        kill(-pid, SIGKILL)
                        if leaderReaped { return }
                    }
                } else if shouldStop() {
                    Log.info("action", "stopping shell command (pid \(pid))")
                    kill(-pid, SIGTERM)
                    termSentAt = Mono.now()
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }
}
