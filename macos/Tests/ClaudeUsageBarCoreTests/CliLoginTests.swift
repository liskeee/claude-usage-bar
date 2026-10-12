import Foundation
import os
import Testing
@testable import ClaudeUsageBarCore

struct CliLoginTests {
    let temp = TempDir()
    let fake = FakeSecurity()
    let a = Logins.make("a", "a@example.com", extraSecure: ["trustedDeviceToken": .string("device-a")])
    let b = Logins.make("b", "b@example.com", org: "org-2")
    var config: URL { temp["home/.claude.json"] }

    func cli(backup: Bool = false) -> CliLogin {
        CliLogin(keychain: SecurityCLI(runner: fake), service: KeychainNames.claudeService, keychainAccount: "tester",
                 globalConfig: config, backupDir: backup ? temp["backup"] : nil,
                 sealBackup: backup ? { @Sendable data in Data(data.reversed()) } : nil)
    }

    var itemData: Data? { fake[KeychainNames.claudeService, "tester"] }
    func item() throws -> [String: JSONValue] { try JSONValue.parse(itemData!).object! }
    func configRoot() throws -> [String: JSONValue] { try JSONValue.parse(Data(contentsOf: config)).object! }

    @Test func readCurrent_readsTheAccountScopedKeysAndOauthAccount() async {
        Logins.writeCli(fake, config: config, a)
        #expect(await cli().readCurrent() == a)
    }

    @Test func readCurrent_withoutALogin_isNil() async throws {
        #expect(await cli().readCurrent() == nil) // nothing at all

        Logins.writeCli(fake, config: config, a)
        try FileManager.default.removeItem(at: config)
        #expect(await cli().readCurrent() == nil) // no global config

        Logins.writeCli(fake, config: config, a)
        fake[KeychainNames.claudeService, "tester"] = Data(#"{"mcpOAuth":{}}"#.utf8)
        #expect(await cli().readCurrent() == nil) // signed out: no claudeAiOauth

        fake[KeychainNames.claudeService, "tester"] = Data("garbage".utf8)
        #expect(await cli().readCurrent() == nil)

        Logins.writeCli(fake, config: config, AccountLogin(secure: a.secure, account: ["emailAddress": .string("x@y.z")]))
        #expect(await cli().readCurrent() == nil) // no accountUuid
    }

    @Test func write_replacesOnlyTheLogin_andKeepsEverythingElse() async throws {
        Logins.writeCli(fake, config: config, a)

        try await cli().write(b)

        let item = try item()
        #expect(item["mcpOAuth"]?["srv|abc"]?["accessToken"]?.string == "mcp-token")
        #expect(item["claudeAiOauth"]?["accessToken"]?.string == "access-b-1")
        #expect(item["organizationUuid"]?.string == "org-2")
        #expect(item["trustedDeviceToken"] == nil) // a's, and b has none
        let root = try configRoot()
        #expect(root["oauthAccount"] == .object(b.account))
        #expect(root["numStartups"] == .int(5))
        #expect(root["projects"]?["/Users/łukasz/zażółć gęślą"] != nil)
        #expect(root["someFutureSetting"]?["nested"] == .array([.int(1), .double(2.5), .string("x")]))
        #expect(root["cachedGrowthBookFeatures"] != nil)
        #expect(root["modelAccessCache"] == nil)
        #expect(root["cachedUsageUtilization"] == nil)
        #expect(await cli().readCurrent() == b)
    }

    @Test func write_itemIsCompactJSON() async throws {
        Logins.writeCli(fake, config: config, a)
        try await cli().write(b)
        #expect(!String(decoding: itemData!, as: UTF8.self).contains("\n"))
    }

    @Test func write_keepsTheConfigPermissions() async throws {
        Logins.writeCli(fake, config: config, a)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        try await cli().write(b)

        #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func write_withoutAnItem_createsIt() async throws {
        Logins.writeCli(fake, config: config, a)
        fake[KeychainNames.claudeService, "tester"] = nil

        try await cli().write(b)

        #expect(try item() == b.secure)
    }

    @Test func write_configChangedOnce_retriesAndKeepsTheOtherChange() async throws {
        Logins.writeCli(fake, config: config, a)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var cli = cli()
        cli.beforeReplace = { url in
            guard calls.withLock({ $0 += 1; return $0 }) == 1 else { return }
            // a running Claude Code session saves its config in between
            var root = try! JSONValue.parse(Data(contentsOf: url)).object!
            root["numStartups"] = .int(6)
            try! JSONValue.object(root).serialized().write(to: url)
        }

        try await cli.write(b)

        let root = try configRoot()
        #expect(root["numStartups"] == .int(6))
        #expect(root["oauthAccount"] == .object(b.account))
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func write_configAlwaysBusy_failsAndRestoresTheItem() async throws {
        Logins.writeCli(fake, config: config, a)
        let itemBefore = itemData
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var cli = cli()
        cli.beforeReplace = { url in
            let n = calls.withLock { $0 += 1; return $0 }
            let handle = try! FileHandle(forWritingTo: url)
            _ = try! handle.seekToEnd()
            try! handle.write(contentsOf: Data(String(repeating: " ", count: n).utf8))
            try! handle.close()
        }

        await #expect(throws: CliLoginError.self) { try await cli.write(b) }

        #expect(itemData == itemBefore)
        #expect(try configRoot()["oauthAccount"] == .object(a.account))
        #expect(calls.withLock { $0 } == 3)
    }

    @Test func write_unparseableConfig_failsAndRestoresTheItem() async throws {
        Logins.writeCli(fake, config: config, a)
        let itemBefore = itemData
        let damaged = try String(contentsOf: config, encoding: .utf8)
            .replacingOccurrences(of: "\"numStartups\": 5", with: "\"numStartups\": 5, \"lastPrompt\": \"x\\ud83dy\"")
        try damaged.write(to: config, atomically: true, encoding: .utf8)

        await #expect(throws: CliLoginError.self) { try await cli().write(b) }

        #expect(itemData == itemBefore)
    }

    @Test func write_itemThatIsNotJSON_isLeftAlone() async throws {
        Logins.writeCli(fake, config: config, a)
        fake[KeychainNames.claudeService, "tester"] = Data("garbage".utf8)

        await #expect(throws: CliLoginError.self) { try await cli().write(b) }

        #expect(itemData == Data("garbage".utf8))
    }

    @Test func write_lockedKeychain_changesNothing() async throws {
        Logins.writeCli(fake, config: config, a)
        let configBefore = try Data(contentsOf: config)
        fake.isLocked = true

        await #expect(throws: CliLoginError.self) { try await cli().write(b) }

        #expect(try Data(contentsOf: config) == configBefore)
    }

    @Test func write_backsUpTheConfigAndTheSealedItem() async throws {
        Logins.writeCli(fake, config: config, a)
        let itemBefore = try #require(itemData)
        let configBefore = try Data(contentsOf: config)

        try await cli(backup: true).write(b)

        #expect(try Data(contentsOf: temp["backup/claude.json"]) == configBefore)
        #expect(try Data(contentsOf: temp["backup/credentials.dat"]) == Data(itemBefore.reversed()))
    }

    @Test func forConfigDir_usesTheSuffixedItemAndTheDirsOwnConfig() async {
        let dir = temp["login-1"]
        let login = CliLogin.forConfigDir(dir, keychain: SecurityCLI(runner: fake), account: "tester")
        Logins.writeCli(fake, service: KeychainNames.claudeService(configDir: dir.path), config: dir.appending(path: ".claude.json"), b)

        #expect(await login.readCurrent() == b)
        await login.deleteItem()
        #expect(fake.services.isEmpty)
    }
}
