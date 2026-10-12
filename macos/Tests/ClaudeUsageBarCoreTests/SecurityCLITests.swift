import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct SecurityCLITests {
    @Test func read_asksForThePasswordOfServiceAndAccount() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data("{\"a\":1}\n".utf8)) }

        let data = try await SecurityCLI(runner: runner).read(service: "svc", account: "me")

        #expect(data == Data("{\"a\":1}".utf8))
        #expect(runner.requests.map(\.arguments) == [["find-generic-password", "-a", "me", "-w", "-s", "svc"]])
        #expect(runner.requests.first?.executable == URL(fileURLWithPath: "/usr/bin/security"))
    }

    @Test func read_hexOutput_isDecoded() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data("00ff10\n".utf8)) }
        #expect(try await SecurityCLI(runner: runner).read(service: "svc", account: "me") == Data([0x00, 0xff, 0x10]))
    }

    @Test func read_missingItem_isNil() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 44) }
        #expect(try await SecurityCLI(runner: runner).read(service: "svc", account: "me") == nil)
    }

    @Test(arguments: [(36, KeychainError.locked), (1, .failed(1))] as [(Int32, KeychainError)])
    func read_otherExitCodes_throw(code: Int32, expected: KeychainError) async {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: code) }
        await #expect(throws: expected) { _ = try await SecurityCLI(runner: runner).read(service: "svc", account: "me") }
    }

    @Test func write_sendsTheCommandOnStdin() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0) }

        try await SecurityCLI(runner: runner).write(service: "svc", account: "me", data: Data("{}".utf8))

        #expect(runner.requests.first?.arguments == ["-i"])
        #expect(runner.requests.first?.stdin == Data("add-generic-password -U -a \"me\" -s \"svc\" -X \"7b7d\"\n".utf8))
    }

    @Test func write_longCommand_goesThroughArguments() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0) }
        let overhead = "add-generic-password -U -a \"me\" -s \"svc\" -X \"\"\n".utf8.count
        let fits = (SecurityCLI.stdinLimit - overhead) / 2

        try await SecurityCLI(runner: runner).write(service: "svc", account: "me", data: Data(repeating: 0x41, count: fits))
        try await SecurityCLI(runner: runner).write(service: "svc", account: "me", data: Data(repeating: 0x41, count: fits + 1))

        #expect(runner.requests[0].arguments == ["-i"])
        #expect(runner.requests[1].arguments.prefix(6) == ["add-generic-password", "-U", "-a", "me", "-s", "svc"])
        #expect(runner.requests[1].stdin == nil)
    }

    @Test func write_lockedKeychain_throws() async {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 36) }
        await #expect(throws: KeychainError.locked) { try await SecurityCLI(runner: runner).write(service: "s", account: "a", data: Data()) }
    }

    @Test func delete_missingItem_isFine_otherFailuresThrow() async throws {
        try await SecurityCLI(runner: RecordingRunner { _ in ProcessResult(exitCode: 44) }).delete(service: "s", account: "a")
        await #expect(throws: KeychainError.failed(1)) {
            try await SecurityCLI(runner: RecordingRunner { _ in ProcessResult(exitCode: 1) }).delete(service: "s", account: "a")
        }
    }

    @Test func fakeSecurity_understandsWhatSecurityCLISends() async throws {
        let fake = FakeSecurity()
        let keychain = SecurityCLI(runner: fake)
        let big = Data(repeating: 0x42, count: 5000)

        try await keychain.write(service: "Claude Code-credentials", account: "me", data: Data("{\"x\":1}".utf8))
        try await keychain.write(service: "other", account: "me", data: big)

        #expect(try await keychain.read(service: "Claude Code-credentials", account: "me") == Data("{\"x\":1}".utf8))
        #expect(fake["other", "me"] == big)
        try await keychain.delete(service: "other", account: "me")
        #expect(fake.services == ["Claude Code-credentials"])
    }
}
