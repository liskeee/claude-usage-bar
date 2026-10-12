import Foundation

public enum UsageAPIResult: Sendable, Equatable {
    case ok(String)
    case unauthorized
    case rateLimited
    case failed(String)

    /// What the log and the popover footer say about a failure.
    public var error: String? {
        switch self {
        case .ok: nil
        case .unauthorized: "HTTP 401"
        case .rateLimited: "HTTP 429"
        case .failed(let message): message
        }
    }
}

@MainActor public protocol UsageAPI {
    func fetch(accessToken: String) async -> UsageAPIResult
}

/// The same endpoint Claude Code's /usage uses.
public struct HTTPUsageAPI: UsageAPI {
    nonisolated public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    let version: String
    let session: URLSession

    public init(version: String, session: URLSession = .shared) {
        self.version = version
        self.session = session
    }

    nonisolated public static func request(accessToken: String, version: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeUsageBar/\(version) (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated public static func result(status: Int, body: Data) -> UsageAPIResult {
        switch status {
        case 401: .unauthorized
        case 429: .rateLimited
        case 200..<300: .ok(String(decoding: body, as: UTF8.self))
        default: .failed("HTTP \(status)")
        }
    }

    public func fetch(accessToken: String) async -> UsageAPIResult {
        do {
            let (body, response) = try await session.data(for: Self.request(accessToken: accessToken, version: version))
            return Self.result(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
