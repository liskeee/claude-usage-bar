import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct ProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test func run_capturesOutputAndExitCode() async throws {
        let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
        #expect(!result.timedOut)
    }

    @Test func run_passesStdinEnvironmentAndDirectory() async throws {
        let request = ProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat; echo \" $X\"; pwd"],
            stdin: Data("hello".utf8), environment: ["X": "42", "PATH": "/usr/bin:/bin"], workingDirectory: URL(fileURLWithPath: "/private/tmp"))
        let result = try await runner.run(request)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello 42\n/private/tmp\n")
    }

    @Test func run_timeout_terminatesTheProgram() async throws {
        let started = Date()
        let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.3))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func run_withoutCapture_returnsEmptyOutput() async throws {
        let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"], captureOutput: false))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }
}
