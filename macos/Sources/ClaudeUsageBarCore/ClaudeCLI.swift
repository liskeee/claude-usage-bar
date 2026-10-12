import Foundation

/// Finding and starting the Claude Code CLI.
public enum ClaudeCLI {
    /// PATH first, then where the installers put it: an app started at login gets a minimal PATH.
    public static func searchDirectories(path: String?, home: URL) -> [URL] {
        let fromPath = (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let known = [home.appending(path: ".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        var seen = Set<String>()
        return (fromPath + known).filter { seen.insert($0.path).inserted }
    }

    public static func find(path: String?, home: URL, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        searchDirectories(path: path, home: home).map { $0.appending(path: "claude") }.first { isExecutable($0.path) }
    }

    public static func findDefault() -> URL? {
        find(path: ProcessInfo.processInfo.environment["PATH"], home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Never pass on auth, config dir or proxy settings from a Claude session that happened to start us.
    public static func cleanEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            let upper = key.uppercased()
            return !upper.hasPrefix("CLAUDE") && !upper.hasPrefix("ANTHROPIC")
        }
    }

    /// The environment for a `claude` child: cleaned, with the installer locations on PATH.
    public static func childEnvironment(_ environment: [String: String], home: URL) -> [String: String] {
        var env = cleanEnvironment(environment)
        env["PATH"] = searchDirectories(path: environment["PATH"], home: home).map(\.path).joined(separator: ":")
        return env
    }
}
