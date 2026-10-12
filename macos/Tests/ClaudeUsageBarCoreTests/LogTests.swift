import Foundation
import Testing
@testable import ClaudeUsageBarCore

// Log is process-wide: these tests don't run in parallel with each other
@Suite(.serialized) struct LogTests {
    let temp = TempDir()

    @Test func write_appendsTimestampedLines() throws {
        Log.configure(directory: temp["logs"])
        Log.write("first")
        Log.write("second")

        let text = try String(contentsOf: temp["logs/app.log"], encoding: .utf8)
        #expect(text.contains(" first\n"))
        #expect(text.contains(" second\n"))
    }

    @Test func configure_keepsOnlyTheLastMegabyte() throws {
        try FileManager.default.createDirectory(at: temp["logs"], withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 1_500_000).write(to: temp["logs/app.log"])

        Log.configure(directory: temp["logs"])

        let size = try FileManager.default.attributesOfItem(atPath: temp["logs/app.log"].path)[.size] as? Int
        #expect(size == 1_000_000)
    }
}
