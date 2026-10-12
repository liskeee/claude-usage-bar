import Foundation

public enum AccountError: Error, Equatable {
    case claudeNotFound
    case loginFailed(String)
    case writeFailed(String)
}

/// Saved accounts ↔ Claude Code's login: captures the active login, switches to a saved one, adds new ones.
/// `cliLock` is shared with the token renewer: a `claude -p` refresh must never write the old account's tokens over
/// a login that was just switched to.
@MainActor public final class AccountSwitcher {
    let cli: CliLogin
    let store: AccountStore
    let cliLock: AsyncLock
    let loginRoot: URL
    let loginFor: (URL) -> CliLogin
    let runLogin: (String?, URL) async throws -> Bool
    let time: any TimeSource
    private var lastSeen: AccountKey? // the last account read from Claude Code; nil until the first read

    public private(set) var active: AccountLogin?
    public private(set) var isLoginRunning = false
    /// Claude Code now has another login (or a fresh one); everything shown for the previous one is stale.
    public var onSwitched: (() -> Void)?

    public init(cli: CliLogin, store: AccountStore, cliLock: AsyncLock, loginRoot: URL,
                loginFor: @escaping (URL) -> CliLogin, runLogin: @escaping (String?, URL) async throws -> Bool, time: any TimeSource) {
        self.cli = cli
        self.store = store
        self.cliLock = cliLock
        self.loginRoot = loginRoot
        self.loginFor = loginFor
        self.runLogin = runLogin
        self.time = time
    }

    public func accounts() async throws -> [SavedAccount] { try await store.all() }

    /// Reads the active login and saves it when it is new or changed: token rotation, `/login` by hand.
    /// Another account signed in by hand raises onSwitched, like a switch from the menu.
    public func sync() async {
        guard let current = await cli.readCurrent() else {
            active = nil
            return
        }
        active = current
        let switchedByHand = lastSeen.map { $0 != current.key } ?? false
        lastSeen = current.key
        await save(current)
        if switchedByHand {
            Log.write("accounts: signed in by hand as \(current)")
            onSwitched?()
        }
    }

    private func save(_ login: AccountLogin) async {
        do {
            let all = try await store.all()
            if let saved = all.first(where: { $0.key == login.key }), saved.login == login { return }
            // another saved account's refresh token under this name is a half-written pair, not a new login: saving it
            // would replace this account's real tokens
            if let token = login.refreshToken, all.contains(where: { $0.key != login.key && $0.login.refreshToken == token }) {
                Log.write("accounts: \(login) carries another account's tokens, not saved")
                return
            }
            try await store.upsert(SavedAccount(login: login, savedAt: time.now()))
            Log.write("accounts: saved \(login)")
        } catch {
            Log.write("accounts: can't save \(login): \(error)")
        }
    }

    public func switchTo(_ key: AccountKey) async throws {
        await cliLock.lock()
        defer { cliLock.unlock() }
        await sync() // the account being left may have rotated its tokens since the last sync
        if active?.key == key { return }
        guard let target = try await store.find(key) else { throw AccountError.writeFailed("no saved account \(key)") }
        try await apply(target.login)
    }

    /// Signs in with `claude auth login` in a throwaway CLAUDE_CONFIG_DIR, so the current login is never signed out,
    /// then saves the new login and switches to it. `email` pre-fills the login page (for "sign in again").
    public func addAccount(email: String?) async throws {
        if isLoginRunning { return }
        isLoginRunning = true
        let dir = loginRoot.appending(path: "login-\(UUID().uuidString.lowercased())")
        do {
            try await addAccount(email: email, in: dir)
        } catch {
            await removeLoginDir(dir) // it holds live tokens
            isLoginRunning = false
            throw error
        }
        await removeLoginDir(dir)
        isLoginRunning = false
    }

    private func addAccount(email: String?, in dir: URL) async throws {
        await removeLeftoverLoginDirs()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard try await runLogin(email, dir) else { throw AccountError.loginFailed("claude auth login failed or was closed") }
        guard let login = await loginFor(dir).readCurrent() else { throw AccountError.loginFailed("claude auth login left no login") }
        await cliLock.lock()
        defer { cliLock.unlock() }
        await sync() // after the login, not before: the account being left may have rotated its tokens meanwhile
        let saved = SavedAccount(login: login, savedAt: time.now())
        if active?.key == login.key {
            // a fresh login of the active account replaces its dead tokens; store it only once Claude Code has it,
            // or the next sync would put the dead tokens back over it anyway
            try await apply(login)
            try await store.upsert(saved)
        } else {
            try await store.upsert(saved)
            try await apply(login)
        }
    }

    /// Forgets a saved account. No server call: its login stays valid wherever else it is used.
    public func remove(_ key: AccountKey) async throws {
        await sync()
        if active?.key == key { throw AccountError.writeFailed("the active account can't be removed") }
        try await store.remove(key)
        Log.write("accounts: removed \(key)")
    }

    private func apply(_ login: AccountLogin) async throws {
        do { try await cli.write(login) }
        catch { throw AccountError.writeFailed("\(error)") }
        active = await cli.readCurrent()
        lastSeen = active?.key ?? lastSeen
        Log.write("accounts: switched to \(login)")
        onSwitched?()
        if active?.key != login.key {
            throw AccountError.writeFailed("Claude Code's login reads back as \(active.map { "\($0)" } ?? "nothing")")
        }
    }

    // a login dir left by a crash or a kill still holds tokens, in the dir and in its own Keychain item;
    // only one login runs at a time, so none is in use
    private func removeLeftoverLoginDirs() async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: loginRoot.path)) ?? []
        for name in names where name.hasPrefix("login-") {
            await removeLoginDir(loginRoot.appending(path: name))
        }
    }

    private func removeLoginDir(_ dir: URL) async {
        await loginFor(dir).deleteItem()
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do { try FileManager.default.removeItem(at: dir) }
        catch { Log.write("accounts: can't delete \(dir.lastPathComponent): \(error)") }
    }
}
