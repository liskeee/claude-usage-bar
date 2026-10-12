import Foundation

/// One Claude account: oauthAccount.accountUuid + organizationUuid (one person can be in several organizations).
public struct AccountKey: Hashable, Sendable, CustomStringConvertible {
    public var accountUuid: String
    public var organizationUuid: String

    public init(accountUuid: String, organizationUuid: String) {
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
    }

    // the log only ever sees uuid prefixes
    public var description: String { "\(accountUuid.prefix(8))/\(organizationUuid.prefix(8))" }
}

/// A Claude Code login as the CLI stores it: the account-scoped keys of its Keychain item (tokens, plan) and
/// `oauthAccount` from its global config (who). Raw JSON, so fields this app doesn't know round-trip unchanged.
public struct AccountLogin: Sendable, Equatable, CustomStringConvertible {
    /// The keys Claude Code removes from its Keychain item on logout: everything that belongs to one account.
    public static let secureKeys = ["claudeAiOauth", "organizationUuid", "trustedDeviceToken", "enterpriseGateway", "designOauth"]

    public let secure: [String: JSONValue]
    public let account: [String: JSONValue]

    public init(secure: [String: JSONValue], account: [String: JSONValue]) {
        self.secure = secure.filter { Self.secureKeys.contains($0.key) }
        self.account = account
    }

    public var key: AccountKey {
        AccountKey(accountUuid: account["accountUuid"]?.string ?? "", organizationUuid: account["organizationUuid"]?.string ?? "")
    }

    public var email: String { account["emailAddress"]?.string ?? "" }
    public var organizationName: String? { account["organizationName"]?.string }
    var oauth: JSONValue? { secure["claudeAiOauth"] }
    public var refreshToken: String? { oauth?["refreshToken"]?.string }

    /// After this the refresh token is dead and only a new `claude auth login` helps; nil when the CLI didn't say.
    public var refreshTokenExpiresAt: Date? {
        oauth?["refreshTokenExpiresAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    public var planName: String {
        Format.planName(subscriptionType: oauth?["subscriptionType"]?.string, rateLimitTier: oauth?["rateLimitTier"]?.string)
    }

    // never let tokens reach logs through string interpolation
    public var description: String { "\(Format.maskEmail(email)) \(key)" }
}

/// A saved login and when it was last captured.
public struct SavedAccount: Sendable, Equatable {
    public var login: AccountLogin
    public var savedAt: Date

    public init(login: AccountLogin, savedAt: Date) {
        self.login = login
        self.savedAt = savedAt
    }

    public var key: AccountKey { login.key }
}
