import Foundation

public struct Credentials: Sendable, Equatable, CustomStringConvertible {
    public var accessToken: String
    public var expiresAt: Date
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date, subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    // never let the token reach logs through string interpolation
    public var description: String { "Credentials(expiresAt: \(expiresAt), plan: \(rateLimitTier ?? subscriptionType ?? "-"))" }
}

@MainActor public protocol CredentialSource {
    /// nil when there is no claude.ai login; throws when the Keychain can't be read (e.g. locked).
    func read() async throws -> Credentials?
}

/// The active Claude Code login, from its Keychain item. Read-only: Claude Code owns the item.
public struct KeychainCredentialStore: CredentialSource {
    let keychain: SecurityCLI
    let service: String
    let account: String

    public init(keychain: SecurityCLI, service: String = KeychainNames.claudeService, account: String = KeychainNames.currentUser) {
        self.keychain = keychain
        self.service = service
        self.account = account
    }

    public func read() async throws -> Credentials? {
        guard let data = try await keychain.read(service: service, account: account),
              let oauth = (try? JSONValue.parse(data))?["claudeAiOauth"],
              let token = oauth["accessToken"]?.string, !token.isEmpty else { return nil }
        let expires = oauth["expiresAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        return Credentials(accessToken: token, expiresAt: expires,
                           subscriptionType: oauth["subscriptionType"]?.string, rateLimitTier: oauth["rateLimitTier"]?.string)
    }
}
