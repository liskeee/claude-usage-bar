import Foundation
import Testing
@testable import ClaudeUsageBarCore

@MainActor struct AccountStoreTests {
    let temp = TempDir()
    let fake = FakeSecurity()
    let now = iso("2026-10-06T12:00:00Z")
    var file: URL { temp["data/accounts.dat"] }

    func store(_ keychain: FakeSecurity? = nil) -> AccountStore {
        AccountStore(file: file, key: AccountsKey(keychain: SecurityCLI(runner: keychain ?? fake)))
    }

    func saved(_ id: String, at offset: TimeInterval = 0) -> SavedAccount {
        SavedAccount(login: Logins.make(id, "\(id)@x.pl"), savedAt: now.addingTimeInterval(offset))
    }

    @Test func savedAccounts_surviveARestart() async throws {
        let first = store()
        try await first.upsert(saved("a"))
        try await first.upsert(saved("b", at: 0.123))

        #expect(try await store().all() == [saved("a"), saved("b", at: 0.123)])
    }

    @Test func upsert_replacesTheSameAccount_removeForgetsIt() async throws {
        let store = store()
        try await store.upsert(saved("a"))
        try await store.upsert(saved("b"))
        try await store.upsert(saved("a", at: 60))

        #expect(try await store.find(saved("a").key)?.savedAt == now.addingTimeInterval(60))
        try await store.remove(saved("a").key)
        #expect(try await store.all().map(\.key) == [saved("b").key])
    }

    @Test func file_isEncrypted_andOnlyForTheUser() async throws {
        try await store().upsert(saved("a"))

        let data = try Data(contentsOf: file)
        #expect(data.range(of: Data("access-a-1".utf8)) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func key_isCreatedOnce_inTheAppsOwnItem() async throws {
        try await store().upsert(saved("a"))
        let stored = try #require(fake[KeychainNames.appService, KeychainNames.accountsKeyAccount])

        try await store().upsert(saved("b"))

        #expect(fake.services == ["ClaudeUsageBar"])
        #expect(fake[KeychainNames.appService, KeychainNames.accountsKeyAccount] == stored)
        #expect(Data(base64Encoded: stored)?.count == 32)
    }

    @Test func unreadableFile_isMovedAside_andTheListStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: file)

        #expect(try await store().all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path + ".bad"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func fileSealedWithAnotherKey_isMovedAside() async throws {
        try await store().upsert(saved("a"))

        #expect(try await store(FakeSecurity()).all().isEmpty) // another Mac user, or the key item was deleted
        #expect(FileManager.default.fileExists(atPath: file.path + ".bad"))
    }

    @Test func lockedKeychain_throws_andLeavesTheFileAlone() async throws {
        try await store().upsert(saved("a"))
        fake.isLocked = true

        await #expect(throws: KeychainError.locked) { _ = try await store().all() }

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.path + ".bad"))
    }
}
