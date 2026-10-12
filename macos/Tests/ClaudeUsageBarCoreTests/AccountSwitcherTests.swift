import Foundation
import os
import Testing
@testable import ClaudeUsageBarCore

@MainActor final class AccountSwitcherTests {
    let now: Date
    let temp: TempDir
    let fake: FakeSecurity
    let time: FakeTime
    let store: AccountStore
    let cliLock = AsyncLock()
    let a = Logins.make("a", "a@example.com")
    let b = Logins.make("b", "b@example.com")
    var logins: [(email: String?, dir: URL)] = []
    /// What the fake `claude auth login` does in its dir.
    var login: (URL) async throws -> Bool = { _ in false }
    var switched = 0

    init() {
        let now = iso("2026-10-06T12:00:00Z"), temp = TempDir(), fake = FakeSecurity()
        self.now = now
        self.temp = temp
        self.fake = fake
        time = FakeTime(now)
        store = AccountStore(file: temp["data/accounts.dat"], key: AccountsKey(keychain: SecurityCLI(runner: fake)))
    }

    var homeConfig: URL { temp["home/.claude.json"] }
    var cli: CliLogin {
        CliLogin(keychain: SecurityCLI(runner: fake), service: KeychainNames.claudeService, keychainAccount: "tester",
                 globalConfig: homeConfig, backupDir: temp["data/backup"])
    }

    func cliNow() async -> AccountLogin? { await cli.readCurrent() }
    func signInCli(_ login: AccountLogin) { Logins.writeCli(fake, config: homeConfig, login) }
    func temporaryService(_ dir: URL) -> String { KeychainNames.claudeService(configDir: dir.path) }

    /// A fake `claude auth login` that signs in as `account` in its dir.
    func logsIn(_ account: AccountLogin) -> (URL) async throws -> Bool {
        { [fake] dir in
            Logins.writeCli(fake, service: KeychainNames.claudeService(configDir: dir.path), config: dir.appending(path: ".claude.json"), account)
            return true
        }
    }

    func make(cli custom: CliLogin? = nil) -> AccountSwitcher {
        let switcher = AccountSwitcher(
            cli: custom ?? cli, store: store, cliLock: cliLock, loginRoot: temp["data"],
            loginFor: { [fake] dir in CliLogin.forConfigDir(dir, keychain: SecurityCLI(runner: fake), account: "tester") },
            runLogin: { [unowned self] email, dir in
                self.logins.append((email, dir))
                return try await self.login(dir)
            },
            time: time)
        switcher.onSwitched = { [unowned self] in self.switched += 1 }
        return switcher
    }

    @Test func sync_savesAnAccountSignedInByHand() async throws {
        signInCli(a)
        let switcher = make()

        await switcher.sync()

        #expect(switcher.active?.key == a.key)
        #expect(try await store.all() == [SavedAccount(login: a, savedAt: now)])
    }

    @Test func sync_unchangedLogin_keepsTheSavedCopy() async throws {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        time.advance(5 * 60)

        await switcher.sync()

        #expect(try await store.all().map(\.savedAt) == [now])
    }

    @Test func sync_rotatedTokens_updateTheSavedCopy() async throws {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        signInCli(Logins.make("a", "a@example.com", token: "2")) // the CLI refreshed its token

        await switcher.sync()

        #expect(Logins.accessToken(try await store.all().first?.login) == "access-a-2")
    }

    @Test func sync_signedOut_savesNothing() async throws {
        let switcher = make()

        await switcher.sync()

        #expect(switcher.active == nil)
        #expect(try await store.all().isEmpty)
    }

    @Test func switchTo_writesTheTarget_andKeepsTheLatestTokensOfTheAccountLeft() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        signInCli(Logins.make("a", "a@example.com", token: "2")) // rotated after the last sync

        try await switcher.switchTo(b.key)

        #expect(await cliNow() == b)
        #expect(switcher.active?.key == b.key)
        #expect(Logins.accessToken(try await store.find(a.key)?.login) == "access-a-2")
        #expect(switched == 1)
    }

    @Test func switchTo_theActiveAccount_changesNothing() async throws {
        signInCli(a)
        let switcher = make()
        let config = try Data(contentsOf: homeConfig)

        try await switcher.switchTo(a.key)

        #expect(try Data(contentsOf: homeConfig) == config)
        #expect(switched == 0)
    }

    @Test func switchTo_waitsWhileTheCliIsRenewingItsToken() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        await cliLock.lock() // a `claude -p` renewal is running

        let switching = Task { try await switcher.switchTo(b.key) }
        for _ in 0..<20 { await Task.yield() }
        #expect(await cliNow() == a)

        cliLock.unlock()
        try await switching.value
        #expect(await cliNow() == b)
        #expect(!cliLock.isLocked)
    }

    @Test func switchTo_unwritableConfig_failsAndKeepsTheActiveAccount() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        try Data("{damaged".utf8).write(to: homeConfig)
        let item = fake[KeychainNames.claudeService, "tester"]

        await #expect(throws: AccountError.self) { try await switcher.switchTo(b.key) }

        #expect(fake[KeychainNames.claudeService, "tester"] == item)
        #expect(switched == 0)
        #expect(!cliLock.isLocked)
    }

    @Test func switchTo_configThatCantBeWrittenBack_failsAndKeepsTheActiveAccount() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let text = try String(contentsOf: homeConfig, encoding: .utf8)
            .replacingOccurrences(of: "\"numStartups\": 5", with: "\"numStartups\": 5, \"lastPrompt\": \"x\\ud83dy\"")
        try text.write(to: homeConfig, atomically: true, encoding: .utf8)
        let switcher = make()

        await #expect(throws: AccountError.self) { try await switcher.switchTo(b.key) }

        #expect(Logins.accessToken(fake[KeychainNames.claudeService, "tester"].flatMap { try? JSONValue.parse($0) }
            .map { AccountLogin(secure: $0.object ?? [:], account: [:]) }) == "access-a-1")
    }

    @Test func addAccount_signsInIsolated_savesTheAccount_andSwitchesToIt() async throws {
        signInCli(a)
        login = { [unowned self] dir in
            #expect(await self.cliNow() == a) // the user's own login stays untouched while signing in
            return try await self.logsIn(self.b)(dir)
        }
        let switcher = make()

        try await switcher.addAccount(email: nil)

        let attempt = try #require(logins.first)
        #expect(logins.count == 1)
        #expect(attempt.email == nil)
        #expect(attempt.dir.path.hasPrefix(temp["data/login-"].path))
        #expect(!FileManager.default.fileExists(atPath: attempt.dir.path))
        #expect(fake[temporaryService(attempt.dir), "tester"] == nil)
        #expect(await cliNow() == b)
        #expect(try await store.find(a.key) != nil)
        #expect(try await store.find(b.key) != nil)
        #expect(switched == 1)
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_loginFailedOrClosed_changesNothing() async throws {
        signInCli(a)
        login = { [unowned self] dir in
            _ = try await self.logsIn(self.b)(dir) // the login got as far as writing its item, then the window was closed
            return false
        }
        let switcher = make()

        await #expect(throws: AccountError.loginFailed("claude auth login failed or was closed")) { try await switcher.addAccount(email: nil) }

        let attempt = try #require(logins.first)
        #expect(await cliNow() == a)
        #expect(!FileManager.default.fileExists(atPath: attempt.dir.path))
        #expect(fake[temporaryService(attempt.dir), "tester"] == nil)
        #expect(switched == 0)
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_exitedWithoutALogin_isAFailedLogin() async {
        signInCli(a)
        login = { _ in true }

        await #expect(throws: AccountError.loginFailed("claude auth login left no login")) { try await self.make().addAccount(email: nil) }

        #expect(await cliNow() == a)
    }

    @Test func addAccount_cancelled_removesTheTempDir() async throws {
        login = { _ in throw CancellationError() }
        let switcher = make()

        await #expect(throws: CancellationError.self) { try await switcher.addAccount(email: nil) }

        #expect(!FileManager.default.fileExists(atPath: try #require(logins.first).dir.path))
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_freshLoginOfTheActiveAccount_replacesItsDeadTokens() async throws {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        login = logsIn(Logins.make("a", "a@example.com", token: "9"))

        try await switcher.addAccount(email: "a@example.com")

        #expect(logins.first?.email == "a@example.com")
        #expect(Logins.accessToken(await cliNow()) == "access-a-9")
        #expect(Logins.accessToken(try await store.all().first?.login) == "access-a-9")
        #expect(try await store.all().count == 1)
        #expect(switched == 1)
    }

    @Test func addAccount_freshLoginOfASavedAccount_refreshesItAndSwitches() async throws {
        try await store.upsert(SavedAccount(login: Logins.make("b", "b@example.com", refreshExpires: now.addingTimeInterval(-86400)), savedAt: now))
        signInCli(a)
        login = logsIn(Logins.make("b", "b@example.com", token: "9"))

        try await make().addAccount(email: "b@example.com")

        #expect(Logins.accessToken(try await store.find(b.key)?.login) == "access-b-9")
        #expect(Logins.accessToken(await cliNow()) == "access-b-9")
        #expect(try await store.find(a.key) != nil) // captured on the way out
    }

    @Test func addAccount_onlyOneLoginAtATime() async throws {
        let finish = Pending<Bool>()
        login = { [unowned self] dir in
            _ = try await self.logsIn(self.b)(dir)
            return await finish.wait()
        }
        let switcher = make()

        let first = Task { try await switcher.addAccount(email: nil) }
        while logins.isEmpty { await Task.yield() }
        #expect(switcher.isLoginRunning)
        try await switcher.addAccount(email: nil) // ignored: returns at once
        finish.resolve(true)
        try await first.value

        #expect(logins.count == 1)
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_removesLoginDirsAndItemsLeftByAnEarlierCrash() async throws {
        let leftover = temp["data/login-0123"]
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        fake[temporaryService(leftover), "tester"] = Data("{}".utf8)

        await #expect(throws: AccountError.self) { try await self.make().addAccount(email: nil) }

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(fake[temporaryService(leftover), "tester"] == nil)
    }

    @Test func removeLeftoverLogins_removesDirsAndItemsFromAnEarlierRun() async throws {
        let leftover = temp["data/login-0123"] // the app quit or crashed while Terminal was still waiting
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        fake[temporaryService(leftover), "tester"] = Data("{}".utf8)

        await make().removeLeftoverLogins()

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(fake[temporaryService(leftover), "tester"] == nil)
    }

    @Test func removeLeftoverLogins_whileALoginRuns_keepsIt() async throws {
        let finish = Pending<Bool>()
        login = { _ in await finish.wait() }
        let switcher = make()
        let adding = Task { try await switcher.addAccount(email: nil) }
        while logins.isEmpty { await Task.yield() }

        await switcher.removeLeftoverLogins()

        let running = try #require(logins.first).dir
        #expect(FileManager.default.fileExists(atPath: running.path))
        #expect(switcher.loginDir == running)
        finish.resolve(false)
        await #expect(throws: AccountError.self) { try await adding.value }
        #expect(switcher.loginDir == nil)
    }

    @Test func cancelLogin_closesTheRunningLoginsScript() async throws {
        let script = Process() // stands in for the Terminal script
        script.executableURL = URL(fileURLWithPath: "/bin/sleep")
        script.arguments = ["30"]
        try script.run()
        let finish = Pending<Bool>()
        login = { dir in
            try "\(script.processIdentifier)\n".write(to: dir.appending(path: "pid"), atomically: true, encoding: .utf8)
            return await finish.wait()
        }
        let switcher = make()
        let adding = Task { try await switcher.addAccount(email: nil) }
        while logins.isEmpty || !FileManager.default.fileExists(atPath: logins[0].dir.appending(path: "pid").path) { await Task.yield() }

        switcher.cancelLogin()

        script.waitUntilExit()
        #expect(script.terminationReason == .uncaughtSignal)
        finish.resolve(false)
        _ = try? await adding.value
    }

    @Test func cancelLogin_withoutARunningLogin_signalsNothing() throws {
        let unrelated = Process() // its pid sits in a login dir left by an earlier run
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { unrelated.terminate() }
        let leftover = temp["data/login-0123"]
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try "\(unrelated.processIdentifier)\n".write(to: leftover.appending(path: "pid"), atomically: true, encoding: .utf8)

        make().cancelLogin()

        Thread.sleep(forTimeInterval: 0.2)
        #expect(unrelated.isRunning)
    }

    @Test func remove_inactiveAccount_forgetsIt_withoutTouchingTheCli() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        let item = fake[KeychainNames.claudeService, "tester"]
        let config = try Data(contentsOf: homeConfig)

        try await switcher.remove(b.key)

        #expect(try await store.find(b.key) == nil)
        #expect(fake[KeychainNames.claudeService, "tester"] == item)
        #expect(try Data(contentsOf: homeConfig) == config)
    }

    @Test func remove_activeAccount_isRefused() async throws {
        signInCli(a)
        let switcher = make()

        await #expect(throws: AccountError.self) { try await switcher.remove(self.a.key) }

        #expect(try await store.find(a.key) != nil)
    }

    @Test func sync_anotherAccountSignedInByHand_raisesSwitched() async {
        signInCli(a)
        let switcher = make()
        await switcher.sync() // what the app found at startup
        signInCli(b) // `/login` as b in a Claude Code session

        await switcher.sync()

        #expect(switcher.active?.key == b.key)
        #expect(switched == 1)
    }

    @Test func sync_firstReadAndTokenRotation_doNotRaiseSwitched() async {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        signInCli(Logins.make("a", "a@example.com", token: "2"))

        await switcher.sync()

        #expect(switched == 0)
    }

    @Test func sync_tokensOfAnotherSavedAccount_areNotSavedUnderThisOne() async throws {
        try await store.upsert(SavedAccount(login: a, savedAt: now))
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        // b's tokens under a's name: a half-finished switch, or the CLI caught between writing its item and its config
        signInCli(AccountLogin(secure: b.secure, account: a.account))

        await make().sync()

        #expect(Logins.accessToken(try await store.find(a.key)?.login) == "access-a-1")
    }

    @Test func addAccount_freshLoginOfTheActiveAccountThatCantBeWritten_keepsStoreAndCliInStep() async throws {
        signInCli(a)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var busy = cli // a busy session rewrites ~/.claude.json every time: the switch gives up after 3 attempts
        busy.beforeReplace = { url in
            let n = calls.withLock { $0 += 1; return $0 }
            let handle = try! FileHandle(forWritingTo: url)
            _ = try! handle.seekToEnd()
            try! handle.write(contentsOf: Data(String(repeating: " ", count: n).utf8))
            try! handle.close()
        }
        let switcher = make(cli: busy)
        await switcher.sync()
        login = logsIn(Logins.make("a", "a@example.com", token: "9"))

        await #expect(throws: AccountError.self) { try await switcher.addAccount(email: "a@example.com") }

        #expect(Logins.accessToken(await cliNow()) == "access-a-1")
        #expect(Logins.accessToken(try await store.all().first?.login) == "access-a-1")
    }
}
