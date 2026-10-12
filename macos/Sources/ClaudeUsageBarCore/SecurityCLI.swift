import Foundation

public enum KeychainError: Error, Equatable {
    case locked
    case failed(Int32)
}

/// The only code that touches the Keychain, always through /usr/bin/security, the way Claude Code does: items it
/// creates trust that tool, so nobody is asked for the keychain password, whatever this app's own signature is.
public struct SecurityCLI: Sendable {
    public static let tool = URL(fileURLWithPath: "/usr/bin/security")
    /// `security -i` reads one command line; Claude Code passes longer commands as arguments.
    public static let stdinLimit = 4032
    static let notFound: Int32 = 44
    static let lockedKeychain: Int32 = 36

    let runner: any ProcessRunner

    public init(runner: any ProcessRunner) { self.runner = runner }

    /// nil when there is no such item.
    public func read(service: String, account: String) async throws -> Data? {
        let result = try await runner.run(ProcessRequest(executable: Self.tool, arguments: ["find-generic-password", "-a", account, "-w", "-s", service]))
        switch result.exitCode {
        case 0: return Self.password(fromOutput: result.stdout)
        case Self.notFound: return nil
        default: throw Self.error(result.exitCode)
        }
    }

    /// Creates or replaces the item. The secret goes in on stdin so it never shows in `ps`, unless it is too long.
    public func write(service: String, account: String, data: Data) async throws {
        let hex = data.hexString
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let request = command.utf8.count <= Self.stdinLimit
            ? ProcessRequest(executable: Self.tool, arguments: ["-i"], stdin: Data(command.utf8))
            : ProcessRequest(executable: Self.tool, arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        let result = try await runner.run(request)
        if result.exitCode != 0 { throw Self.error(result.exitCode) }
    }

    /// Deleting an item that isn't there is fine.
    public func delete(service: String, account: String) async throws {
        let result = try await runner.run(ProcessRequest(executable: Self.tool, arguments: ["delete-generic-password", "-a", account, "-s", service]))
        if result.exitCode != 0 && result.exitCode != Self.notFound { throw Self.error(result.exitCode) }
    }

    static func error(_ code: Int32) -> KeychainError { code == lockedKeychain ? .locked : .failed(code) }

    /// `security -w` prints the secret and a newline; a secret that isn't printable text comes out as hex.
    /// Our secrets are JSON (starts with "{") or base64 (has non-hex characters), so they are never mistaken for hex.
    static func password(fromOutput output: Data) -> Data {
        var text = String(decoding: output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        if !text.isEmpty, text.allSatisfy(\.isHexDigit), let bytes = Data(hex: text) { return bytes }
        return Data(text.utf8)
    }
}
