import Foundation

@MainActor public protocol TokenRenewing: AnyObject {
    /// Asks the official CLI to refresh its login; false when throttled, missing or failed.
    func tryRenew() async -> Bool
    /// Forgets the last attempt: after an account switch the new login may renew right away.
    func reset()
}

/// Renews the Claude Code login with one tiny `claude -p` call: the CLI refreshes its own Keychain item.
@MainActor public final class CliTokenRenewer: TokenRenewing {
    nonisolated public static let minInterval: TimeInterval = 30 * 60
    nonisolated public static let runTimeout: TimeInterval = 90
    nonisolated public static let arguments = ["-p", "ok", "--model", "haiku", "--safe-mode", "--no-session-persistence"]

    let time: any TimeSource
    let cliLock: AsyncLock
    let runCli: @MainActor () async -> Bool
    private var lastAttempt: Date?

    public init(time: any TimeSource, cliLock: AsyncLock, runCli: @escaping @MainActor () async -> Bool) {
        self.time = time
        self.cliLock = cliLock
        self.runCli = runCli
    }

    public func tryRenew() async -> Bool {
        let now = time.now()
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.minInterval { return false }
        lastAttempt = now
        await cliLock.lock()
        defer { cliLock.unlock() }
        return await runCli()
    }

    public func reset() { lastAttempt = nil }

    public static func standard(runner: any ProcessRunner, workDir: URL, cliLock: AsyncLock, time: any TimeSource = SystemTime()) -> CliTokenRenewer {
        CliTokenRenewer(time: time, cliLock: cliLock) {
            guard let claude = ClaudeCLI.findDefault() else {
                Log.write("renew: claude not found")
                return false
            }
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let request = ProcessRequest(
                executable: claude, arguments: arguments,
                environment: ClaudeCLI.childEnvironment(ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser),
                workingDirectory: workDir, timeout: runTimeout, captureOutput: false)
            guard let result = try? await runner.run(request) else {
                Log.write("renew: claude didn't start")
                return false
            }
            Log.write(result.timedOut ? "renew: claude timed out" : "renew: claude exited with \(result.exitCode)")
            return result.exitCode == 0 && !result.timedOut
        }
    }
}
