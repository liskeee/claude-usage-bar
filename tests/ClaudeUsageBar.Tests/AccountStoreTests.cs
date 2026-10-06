using System.Security.Cryptography;
using System.Text;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public sealed class AccountStoreTests : IDisposable
{
    static readonly DateTimeOffset SavedAt = new(2026, 10, 6, 10, 0, 0, TimeSpan.Zero);
    readonly TempDir temp = new();
    readonly AccountLogin a = Logins.Make("a", "a@example.com");

    string StorePath => temp["data/accounts.dat"];

    public void Dispose() => temp.Dispose();

    [Fact]
    public void MissingFile_IsAnEmptyList() => Assert.Empty(new AccountStore(StorePath).All);

    [Fact]
    public void Upsert_SurvivesARestart()
    {
        new AccountStore(StorePath).Upsert(new SavedAccount(a, SavedAt));

        var loaded = Assert.Single(new AccountStore(StorePath).All);
        Assert.Equal(a.Key, loaded.Key);
        Assert.Equal(SavedAt, loaded.SavedAt);
        Assert.True(loaded.Login.SameAs(a));
    }

    [Fact]
    public void File_IsEncrypted()
    {
        new AccountStore(StorePath).Upsert(new SavedAccount(a, SavedAt));

        var raw = Encoding.Latin1.GetString(File.ReadAllBytes(StorePath));
        Assert.DoesNotContain("a@example.com", raw);
        Assert.DoesNotContain("refresh-a-1", raw);
    }

    [Fact]
    public void Upsert_SameKey_ReplacesTheEntry()
    {
        var store = new AccountStore(StorePath);
        store.Upsert(new SavedAccount(a, SavedAt));

        store.Upsert(new SavedAccount(Logins.Make("a", "a@example.com", token: "2"), SavedAt.AddHours(1)));

        var saved = Assert.Single(new AccountStore(StorePath).All);
        Assert.Equal("access-a-2", Logins.AccessToken(saved.Login));
        Assert.Equal(SavedAt.AddHours(1), saved.SavedAt);
    }

    [Fact]
    public void Upsert_SamePersonInAnotherOrganization_IsASecondEntry()
    {
        var store = new AccountStore(StorePath);
        store.Upsert(new SavedAccount(a, SavedAt));

        store.Upsert(new SavedAccount(Logins.Make("a", "a@example.com", org: "org-2"), SavedAt));

        Assert.Equal(2, new AccountStore(StorePath).All.Count);
    }

    [Fact]
    public void FindAndRemove_WorkByKey()
    {
        var store = new AccountStore(StorePath);
        var b = Logins.Make("b", "b@example.com");
        store.Upsert(new SavedAccount(a, SavedAt));
        store.Upsert(new SavedAccount(b, SavedAt));

        store.Remove(a.Key);

        Assert.Null(store.Find(a.Key));
        Assert.NotNull(store.Find(b.Key));
        Assert.Equal(b.Key, Assert.Single(new AccountStore(StorePath).All).Key);
    }

    [Fact]
    public void UndecryptableFile_IsMovedAside_AndTheListStartsEmpty()
    {
        Directory.CreateDirectory(temp["data"]);
        File.WriteAllBytes(StorePath, [1, 2, 3, 4]); // e.g. written by another Windows user

        var store = new AccountStore(StorePath);

        Assert.Empty(store.All);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, File.ReadAllBytes(StorePath + ".bad"));
        store.Upsert(new SavedAccount(a, SavedAt));
        Assert.Single(new AccountStore(StorePath).All);
    }

    [Fact]
    public void DecryptableButDamagedList_IsMovedAside()
    {
        Directory.CreateDirectory(temp["data"]);
        File.WriteAllBytes(StorePath, ProtectedData.Protect("""{"version":1,"accounts":[{"savedAt":"x"}]}"""u8.ToArray(),
            "ClaudeUsageBar.accounts.v1"u8.ToArray(), DataProtectionScope.CurrentUser));

        Assert.Empty(new AccountStore(StorePath).All);
        Assert.True(File.Exists(StorePath + ".bad"));
    }

    [Fact]
    public void LockedFile_IsNotMistakenForADamagedOne()
    {
        new AccountStore(StorePath).Upsert(new SavedAccount(a, SavedAt));

        using (new FileStream(StorePath, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<IOException>(() => new AccountStore(StorePath).All);

        Assert.False(File.Exists(StorePath + ".bad"));
        Assert.Single(new AccountStore(StorePath).All);
    }
}
