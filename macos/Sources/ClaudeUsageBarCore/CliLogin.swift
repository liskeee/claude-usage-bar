import Foundation

public enum CliLoginError: Error, Equatable {
    case notWritten(String)
}

/// Claude Code's login: the account-scoped keys of its Keychain item and `oauthAccount` in its global config.
/// The only code that writes Claude Code's data. It replaces those keys, drops the account caches (as
/// `claude auth logout` does) and leaves everything else (`mcpOAuth`, projects, keys it doesn't know) as it was.
public struct CliLogin: Sendable {
    /// Global config keys Claude Code removes on logout: they describe the previous account.
    public static let accountCaches = [
        "subscriptionNoticeCount", "hasAvailableSubscription", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
        "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster", "artifactRosterDenied",
        "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots", "autoCompactWindowsCache", "cachedUsageUtilization",
    ]
    static let attempts = 3

    let keychain: SecurityCLI
    let service: String
    let keychainAccount: String
    let globalConfig: URL
    let backupDir: URL?
    /// Encrypts the backup of the Keychain item (it holds live tokens); nil: the item isn't backed up.
    let sealBackup: (@Sendable (Data) async throws -> Data)?
    /// Test hook: runs between reading the config and replacing it, where a running Claude Code session may write it.
    var beforeReplace: (@Sendable (URL) -> Void)?

    public init(keychain: SecurityCLI, service: String, keychainAccount: String, globalConfig: URL,
                backupDir: URL? = nil, sealBackup: (@Sendable (Data) async throws -> Data)? = nil) {
        self.keychain = keychain
        self.service = service
        self.keychainAccount = keychainAccount
        self.globalConfig = globalConfig
        self.backupDir = backupDir
        self.sealBackup = sealBackup
    }

    /// The login in the user's home: the default item and ~/.claude.json.
    public static func standard(keychain: SecurityCLI, paths: AppPaths, sealBackup: @escaping @Sendable (Data) async throws -> Data) -> CliLogin {
        CliLogin(keychain: keychain, service: KeychainNames.claudeService, keychainAccount: KeychainNames.currentUser,
                 globalConfig: paths.claudeGlobalConfig, backupDir: paths.backupDir, sealBackup: sealBackup)
    }

    /// The login of a CLI run with CLAUDE_CONFIG_DIR=<dir>: its own item and <dir>/.claude.json.
    public static func forConfigDir(_ dir: URL, keychain: SecurityCLI, account: String = KeychainNames.currentUser) -> CliLogin {
        CliLogin(keychain: keychain, service: KeychainNames.claudeService(configDir: dir.path), keychainAccount: account,
                 globalConfig: dir.appending(path: ".claude.json"))
    }

    /// nil when the item or the file is missing or unreadable, or holds no claude.ai login.
    public func readCurrent() async -> AccountLogin? {
        guard let data = try? await keychain.read(service: service, account: keychainAccount),
              let item = (try? JSONValue.parse(data))?.object, item["claudeAiOauth"]?.object != nil,
              let config = try? Data(contentsOf: globalConfig),
              let account = (try? JSONValue.parse(config))?["oauthAccount"]?.object else { return nil }
        let login = AccountLogin(secure: item, account: account)
        return login.key.accountUuid.isEmpty ? nil : login
    }

    /// Makes `login` Claude Code's login. Throws when something can't be written; the old login then stays whole.
    public func write(_ login: AccountLogin) async throws {
        let itemBefore: Data?
        do { itemBefore = try await keychain.read(service: service, account: keychainAccount) }
        catch { throw CliLoginError.notWritten("keychain: \(error)") }
        var item: [String: JSONValue] = [:]
        if let itemBefore {
            guard let parsed = (try? JSONValue.parse(itemBefore))?.object else {
                throw CliLoginError.notWritten("the Keychain item is not a JSON object")
            }
            item = parsed
        }
        try await backup(itemBefore)

        for key in AccountLogin.secureKeys { item.removeValue(forKey: key) }
        item.merge(login.secure) { _, new in new }
        do { try await keychain.write(service: service, account: keychainAccount, data: try JSONValue.object(item).serialized(pretty: false)) }
        catch { throw CliLoginError.notWritten("keychain: \(error)") }

        do {
            try await updateConfig { config in
                config["oauthAccount"] = .object(login.account)
                for key in Self.accountCaches { config.removeValue(forKey: key) }
            }
        } catch {
            await restoreItem(itemBefore) // one account's tokens under another account's name would be worse
            throw error
        }
    }

    /// Only for the temporary login of "Add account".
    public func deleteItem() async {
        try? await keychain.delete(service: service, account: keychainAccount)
    }

    func updateConfig(_ edit: (inout [String: JSONValue]) -> Void) async throws {
        var lastError: any Error = CliLoginError.notWritten("not attempted")
        for attempt in 1...Self.attempts {
            do {
                try replaceConfig(edit)
                return
            } catch {
                lastError = error
                Log.write("login: \(globalConfig.lastPathComponent), attempt \(attempt) of \(Self.attempts): \(error)")
                if attempt < Self.attempts { try? await Task.sleep(for: .milliseconds(50 * attempt)) }
            }
        }
        throw CliLoginError.notWritten("\(globalConfig.lastPathComponent) not written: \(lastError)")
    }

    /// Read → edit → atomic replace, keeping the file's permissions. Running sessions rewrite ~/.claude.json often:
    /// when it changed after we read it, this throws and the caller starts over from its new content.
    func replaceConfig(_ edit: (inout [String: JSONValue]) -> Void) throws {
        let before = try ConfigFile.read(globalConfig)
        var root = before?.root ?? [:]
        edit(&root)
        let directory = globalConfig.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(path: ".\(globalConfig.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        try ConfigFile.writePrivate(try JSONValue.object(root).serialized(), to: temp)
        if let permissions = before?.permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        beforeReplace?(globalConfig)
        if ConfigFile.changed(globalConfig, since: before) {
            throw CliLoginError.notWritten("\(globalConfig.lastPathComponent) changed while being updated")
        }
        guard rename(temp.path, globalConfig.path) == 0 else { throw CliLoginError.notWritten("rename failed: errno \(errno)") }
    }

    /// The config and the (sealed) Keychain item as they were before the last switch.
    func backup(_ item: Data?) async throws {
        guard let backupDir else { return }
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDir.path)
            let configCopy = backupDir.appending(path: "claude.json")
            try? FileManager.default.removeItem(at: configCopy)
            if FileManager.default.fileExists(atPath: globalConfig.path) {
                try FileManager.default.copyItem(at: globalConfig, to: configCopy)
            }
            if let item, let sealBackup {
                let sealed = try await sealBackup(item)
                let target = backupDir.appending(path: "credentials.dat")
                try? FileManager.default.removeItem(at: target)
                try ConfigFile.writePrivate(sealed, to: target)
            }
        } catch {
            throw CliLoginError.notWritten("backup: \(error)")
        }
    }

    func restoreItem(_ data: Data?) async {
        do {
            if let data {
                try await keychain.write(service: service, account: keychainAccount, data: data)
            } else {
                try await keychain.delete(service: service, account: keychainAccount)
            }
        } catch {
            Log.write("login: couldn't restore the Keychain item: \(error)")
        }
    }
}

/// The global config as read, and the file's state at that moment.
struct ConfigFile {
    let root: [String: JSONValue]
    let modified: Date?
    let size: Int?
    let permissions: Int?

    /// nil when the file doesn't exist; throws when it can't be read or isn't a JSON object.
    static func read(_ url: URL) throws -> ConfigFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // taken before reading: a write after this point counts as a change
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let root = try JSONValue.parse(Data(contentsOf: url)).object else {
            throw CliLoginError.notWritten("\(url.lastPathComponent) is not a JSON object")
        }
        return ConfigFile(root: root, modified: attributes[.modificationDate] as? Date,
                          size: (attributes[.size] as? NSNumber)?.intValue,
                          permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    /// A new file only the user can read from its first byte: the config names the account and every project,
    /// and a file written first and restricted afterwards would be readable by others in between.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CliLoginError.notWritten("can't create \(url.lastPathComponent): errno \(errno)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    static func changed(_ url: URL, since before: ConfigFile?) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return before != nil }
        guard let before else { return true }
        return attributes[.modificationDate] as? Date != before.modified || (attributes[.size] as? NSNumber)?.intValue != before.size
    }
}
