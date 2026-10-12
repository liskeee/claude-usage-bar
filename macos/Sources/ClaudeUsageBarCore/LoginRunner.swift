import Foundation

/// Runs `claude auth login` for a new account in its own Terminal window, isolated with CLAUDE_CONFIG_DIR=<dir>, so
/// the user's current login is never touched. The script reports back through files in <dir>: `pid`, `exit-code`.
public struct LoginRunner: Sendable {
    let claude: URL
    let hint: String
    let openTerminal: @Sendable (URL) async throws -> Void
    let pollInterval: Duration
    let startTimeout: TimeInterval

    public init(claude: URL, hint: String, openTerminal: @escaping @Sendable (URL) async throws -> Void,
                pollInterval: Duration = .seconds(1), startTimeout: TimeInterval = 60) {
        self.claude = claude
        self.hint = hint
        self.openTerminal = openTerminal
        self.pollInterval = pollInterval
        self.startTimeout = startTimeout
    }

    /// Opens the script with Terminal: no Automation permission needed, unlike AppleScript.
    public static func terminal(runner: any ProcessRunner) -> @Sendable (URL) async throws -> Void {
        { script in
            let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Terminal", script.path]))
            if result.exitCode != 0 { throw AccountError.loginFailed("open -a Terminal exited with \(result.exitCode)") }
        }
    }

    // anything else is not passed on; the user then types the address in the browser
    static func isPlainEmail(_ email: String) -> Bool {
        email.wholeMatch(of: #/[A-Za-z0-9._+\-]+@[A-Za-z0-9.\-]+/#) != nil
    }

    /// zsh single quotes: nothing inside is interpreted.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func script(claude: URL, email: String?, hint: String, dir: URL) -> String {
        var login = "\(quote(claude.path)) auth login"
        if let email, isPlainEmail(email) { login += " --email \(quote(email))" }
        return """
            #!/bin/zsh
            echo $$ > \(quote(dir.path + "/pid"))
            print -r -- \(quote(hint))
            print
            for name in $(env | cut -d= -f1 | grep -iE '^(CLAUDE|ANTHROPIC)'); do unset "$name"; done
            export CLAUDE_CONFIG_DIR=\(quote(dir.path))
            \(login)
            echo $? > \(quote(dir.path + "/exit-code"))
            """
    }

    /// True when the login finished; false when it failed or its window was closed. Cancelling closes it.
    public func run(email: String?, dir: URL) async throws -> Bool {
        let script = dir.appending(path: "login.command")
        try Self.script(claude: claude, email: email, hint: hint, dir: dir).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try await openTerminal(script)
        let started = Date()
        while true {
            if let code = Self.readInt(dir.appending(path: "exit-code")) {
                Log.write("login: claude auth login exited with \(code)")
                return code == 0
            }
            if let pid = Self.readInt(dir.appending(path: "pid")) {
                if kill(pid_t(pid), 0) != 0 && errno == ESRCH {
                    // gone without an exit code: the window was closed (look once more: it may have just finished)
                    Log.write("login: the Terminal window was closed")
                    return Self.readInt(dir.appending(path: "exit-code")) == 0
                }
            } else if Date().timeIntervalSince(started) > startTimeout {
                Log.write("login: the Terminal script never started")
                return false
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                if let pid = Self.readInt(dir.appending(path: "pid")) { kill(pid_t(pid), SIGHUP) }
                throw error
            }
        }
    }

    public static func readInt(_ url: URL) -> Int? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
