import CryptoKit
import Foundation

/// The key that encrypts accounts.dat and the Keychain backup. It lives in this app's own Keychain item, written
/// through `security`, so a rebuilt app is never asked for the keychain password. Created on first use.
@MainActor public final class AccountsKey {
    let keychain: SecurityCLI
    let account: String
    private var cached: SymmetricKey?

    public init(keychain: SecurityCLI, account: String = KeychainNames.accountsKeyAccount) {
        self.keychain = keychain
        self.account = account
    }

    /// Throws while the Keychain can't be read (locked): a new key then would make the saved accounts unreadable.
    public func key() async throws -> SymmetricKey {
        if let cached { return cached }
        if let stored = try await keychain.read(service: KeychainNames.appService, account: account),
           let bytes = Data(base64Encoded: stored), bytes.count == 32 {
            let key = SymmetricKey(data: bytes)
            cached = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        // base64 is printable text, so `security -w` hands it back as it is
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedData()
        try await keychain.write(service: KeychainNames.appService, account: account, data: encoded)
        cached = key
        return key
    }

    public func seal(_ data: Data) async throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: try await key()).combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    public func open(_ data: Data) async throws -> Data {
        let key = try await key()
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

/// Saved accounts in accounts.dat: one JSON list, encrypted with AccountsKey. Shaped like the Windows file, except
/// that `secure` holds every account-scoped Keychain key.
@MainActor public final class AccountStore {
    let file: URL
    let key: AccountsKey
    private var accounts: [SavedAccount]?

    public init(file: URL, key: AccountsKey) {
        self.file = file
        self.key = key
    }

    /// Throws while the key can't be read (locked Keychain); nothing is cached then, so the next call tries again.
    public func all() async throws -> [SavedAccount] {
        if let accounts { return accounts }
        let loaded = try await load()
        accounts = loaded
        return loaded
    }

    public func find(_ key: AccountKey) async throws -> SavedAccount? {
        try await all().first { $0.key == key }
    }

    public func upsert(_ account: SavedAccount) async throws {
        var list = try await all()
        if let index = list.firstIndex(where: { $0.key == account.key }) {
            list[index] = account
        } else {
            list.append(account)
        }
        try await save(list)
    }

    public func remove(_ key: AccountKey) async throws {
        try await save(try await all().filter { $0.key != key })
    }

    private func load() async throws -> [SavedAccount] {
        guard let sealed = try? Data(contentsOf: file) else { return [] }
        let plain: Data
        do {
            plain = try await key.open(sealed)
        } catch let error as KeychainError {
            throw error
        } catch {
            return moveAside("can't be decrypted")
        }
        guard let root = try? JSONValue.parse(plain), case .array(let entries)? = root["accounts"] else {
            return moveAside("has no account list")
        }
        let parsed = entries.compactMap(Self.parse)
        guard parsed.count == entries.count else { return moveAside("has an unreadable entry") }
        return parsed
    }

    // another Mac user's file, a lost key or a damaged file: keep it aside and start over
    private func moveAside(_ why: String) -> [SavedAccount] {
        Log.write("accounts: \(file.lastPathComponent) \(why), moved to .bad")
        let bad = file.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: file, to: bad)
        return []
    }

    private func save(_ list: [SavedAccount]) async throws {
        let root = JSONValue.object(["version": .int(1), "accounts": .array(list.map(Self.entry))])
        let sealed = try await key.seal(try root.serialized(pretty: false))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        accounts = list
    }

    static func entry(_ account: SavedAccount) -> JSONValue {
        .object([
            // seconds since Date's own reference date: round-trips exactly, unlike a 1970-based value
            "savedAt": .double(account.savedAt.timeIntervalSinceReferenceDate),
            "secure": .object(account.login.secure),
            "oauthAccount": .object(account.login.account),
        ])
    }

    static func parse(_ entry: JSONValue) -> SavedAccount? {
        guard let savedAt = entry["savedAt"]?.number, let secure = entry["secure"]?.object, let account = entry["oauthAccount"]?.object else {
            return nil
        }
        return SavedAccount(login: AccountLogin(secure: secure, account: account), savedAt: Date(timeIntervalSinceReferenceDate: savedAt))
    }
}
