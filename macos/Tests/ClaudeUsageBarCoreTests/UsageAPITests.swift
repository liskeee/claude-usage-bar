import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct UsageAPITests {
    @Test func request_isTheClaudeCodeUsageCall() {
        let request = HTTPUsageAPI.request(accessToken: "tok", version: "1.2.3")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeUsageBar/1.2.3 (macOS)")
        #expect(request.timeoutInterval == 15)
    }

    @Test(arguments: [
        (200, UsageAPIResult.ok("{}")), (401, .unauthorized), (429, .rateLimited), (503, .failed("HTTP 503")), (0, .failed("HTTP 0")),
    ] as [(Int, UsageAPIResult)])
    func result_mapsTheStatus(status: Int, expected: UsageAPIResult) {
        #expect(HTTPUsageAPI.result(status: status, body: Data("{}".utf8)) == expected)
    }

    @Test func error_isWhatTheFooterShows() {
        #expect(UsageAPIResult.unauthorized.error == "HTTP 401")
        #expect(UsageAPIResult.rateLimited.error == "HTTP 429")
        #expect(UsageAPIResult.failed("offline").error == "offline")
        #expect(UsageAPIResult.ok("{}").error == nil)
    }
}
