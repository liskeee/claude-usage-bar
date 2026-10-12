import Foundation
import os

/// ~/Library/Logs/ClaudeUsageBar/app.log, one timestamped line per event.
/// Never tokens: only masked e-mails and uuid prefixes.
public enum Log {
    static let maxSize = 1_000_000
    private static let file = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Starts logging into `directory`, keeping only the last 1 MB of earlier runs.
    public static func configure(directory: URL) {
        let url = directory.appending(path: "app.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), data.count > maxSize {
            try? data.suffix(maxSize).write(to: url, options: .atomic)
        }
        file.withLock { $0 = url }
    }

    public static func write(_ message: String) {
        let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
        file.withLock { url in
            guard let url else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
