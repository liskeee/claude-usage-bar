import Foundation
import os

public struct ProcessRequest: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var stdin: Data?
    /// nil: inherit the app's environment.
    public var environment: [String: String]?
    public var workingDirectory: URL?
    public var timeout: TimeInterval
    /// false sends output to /dev/null: for programs whose children may keep a pipe open (claude).
    public var captureOutput: Bool

    public init(executable: URL, arguments: [String], stdin: Data? = nil, environment: [String: String]? = nil,
                workingDirectory: URL? = nil, timeout: TimeInterval = 10, captureOutput: Bool = true) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.captureOutput = captureOutput
    }
}

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Every external program (security, claude, open) runs through this, so tests can replace it.
public protocol ProcessRunner: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result(catching: { try Self.runBlocking(request) }))
            }
        }
    }

    static func runBlocking(_ request: ProcessRequest) throws -> ProcessResult {
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        if let environment = request.environment { process.environment = environment }
        if let directory = request.workingDirectory { process.currentDirectoryURL = directory }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = request.captureOutput ? output : FileHandle.nullDevice
        process.standardError = request.captureOutput ? errors : FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // read both pipes while the program runs: a full pipe would block it
        let collected = OSAllocatedUnfairLock(initialState: (out: Data(), err: Data()))
        let readers = DispatchGroup()
        if request.captureOutput {
            for (handle, isOutput) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = handle.readDataToEndOfFile()
                    collected.withLock { if isOutput { $0.out = data } else { $0.err = data } }
                    readers.leave()
                }
            }
        }
        if let stdin = request.stdin { try? input.fileHandleForWriting.write(contentsOf: stdin) }
        try? input.fileHandleForWriting.close()

        let timedOut = finished.wait(timeout: .now() + request.timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        readers.wait()
        let (out, err) = collected.withLock { ($0.out, $0.err) }
        return ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }
}
