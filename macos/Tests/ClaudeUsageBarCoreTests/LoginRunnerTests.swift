import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct LoginRunnerTests {
    let temp = TempDir()

    struct NoPid: Error {}

    /// A stand-in for `claude`: records its arguments and environment, then exits with `exitCode` after `delay` s.
    func fakeClaude(exitCode: Int, delay: Double = 0) throws -> URL {
        let url = temp["bin/claude"]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            #!/bin/sh
            echo "$@" > "$CLAUDE_CONFIG_DIR/args.txt"
            env > "$CLAUDE_CONFIG_DIR/env.txt"
            sleep \(delay)
            exit \(exitCode)
            """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Starts the script the way Terminal would: detached (reaped by launchd), with Claude variables around.
    static let zsh: @Sendable (URL) async throws -> Void = { script in
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_API_KEY"] = "sk-test"
        env["CLAUDE_CODE_ENTRYPOINT"] = "cli"
        _ = try await SystemProcessRunner().run(ProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/bin/zsh \"$0\" >/dev/null 2>&1 &", script.path],
            environment: env, captureOutput: false))
    }

    func loginDir(_ name: String) throws -> URL {
        let dir = temp[name]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func waitForPid(in dir: URL) async throws -> pid_t {
        for _ in 0..<250 {
            if let pid = LoginRunner.readInt(dir.appending(path: "pid")) { return pid_t(pid) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NoPid()
    }

    @Test func script_quotesEverything_andDropsAnEmailThatIsntPlain() {
        let script = LoginRunner.script(claude: URL(fileURLWithPath: "/Users/O'Brien/.local/bin/claude"), email: "a@b.pl; rm -rf ~",
                                        hint: "It's fine", dir: URL(fileURLWithPath: "/tmp/x y"))
        #expect(script.contains("'/Users/O'\\''Brien/.local/bin/claude' auth login\n"))
        #expect(script.contains("export CLAUDE_CONFIG_DIR='/tmp/x y'\n"))
        #expect(script.contains("print -r -- 'It'\\''s fine'\n"))
        #expect(!script.contains("rm -rf"))
    }

    @Test func script_passesAPlainEmail() {
        let script = LoginRunner.script(claude: URL(fileURLWithPath: "/c"), email: "jan.k+1@firma.pl", hint: "h", dir: URL(fileURLWithPath: "/d"))
        #expect(script.contains("'/c' auth login --email 'jan.k+1@firma.pl'\n"))
    }

    @Test func run_successfulLogin_returnsTrue_withACleanEnvironment() async throws {
        let dir = try loginDir("login-1")
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 0), hint: "Sign in", openTerminal: Self.zsh, pollInterval: .milliseconds(20))

        #expect(try await runner.run(email: "a@b.pl", dir: dir))

        let env = try String(contentsOf: dir.appending(path: "env.txt"), encoding: .utf8)
        #expect(env.contains("CLAUDE_CONFIG_DIR=\(dir.path)\n"))
        #expect(!env.contains("ANTHROPIC_API_KEY"))
        #expect(!env.contains("CLAUDE_CODE_ENTRYPOINT"))
        #expect(try String(contentsOf: dir.appending(path: "args.txt"), encoding: .utf8) == "auth login --email a@b.pl\n")
    }

    @Test func run_failedLogin_returnsFalse() async throws {
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 1), hint: "x", openTerminal: Self.zsh, pollInterval: .milliseconds(20))
        #expect(try await runner.run(email: nil, dir: try loginDir("login-2")) == false)
    }

    @Test func run_windowClosed_returnsFalse() async throws {
        let dir = try loginDir("login-3")
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 0, delay: 3), hint: "x", openTerminal: Self.zsh, pollInterval: .milliseconds(20))
        let running = Task { try await runner.run(email: nil, dir: dir) }

        kill(try await waitForPid(in: dir), SIGHUP) // what closing the Terminal window does

        #expect(try await running.value == false)
    }

    @Test func run_scriptNeverStarts_returnsFalse() async throws {
        let runner = LoginRunner(claude: URL(fileURLWithPath: "/usr/bin/false"), hint: "x", openTerminal: { _ in },
                                 pollInterval: .milliseconds(20), startTimeout: 0.2)
        #expect(try await runner.run(email: nil, dir: try loginDir("login-4")) == false)
    }

    @Test func run_cancelled_closesTheScriptAndThrows() async throws {
        let dir = try loginDir("login-5")
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 0, delay: 3), hint: "x", openTerminal: Self.zsh, pollInterval: .milliseconds(20))
        let running = Task { try await runner.run(email: nil, dir: dir) }
        let pid = try await waitForPid(in: dir)

        running.cancel()

        await #expect(throws: CancellationError.self) { _ = try await running.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(pid, 0) != 0)
    }
}
