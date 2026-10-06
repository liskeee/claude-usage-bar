using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeUsageBar.Core;

/// A saved login and when it was last captured. E-mail, organization, plan and expiry come from the raw login.
public sealed record SavedAccount(AccountLogin Login, DateTimeOffset SavedAt)
{
    public AccountKey Key => Login.Key;
}

/// Saved accounts in accounts.dat: one JSON list, encrypted with DPAPI for the current Windows user.
public sealed class AccountStore(string path)
{
    static readonly byte[] Entropy = "ClaudeUsageBar.accounts.v1"u8.ToArray();

    List<SavedAccount>? accounts;

    /// Throws IOException while the file can't be opened (then nothing is cached and the next call tries again).
    public IReadOnlyList<SavedAccount> All => accounts ??= Load();

    public SavedAccount? Find(AccountKey key) => All.FirstOrDefault(a => a.Key == key);

    public void Upsert(SavedAccount account)
    {
        var list = All.ToList();
        int i = list.FindIndex(a => a.Key == account.Key);
        if (i >= 0) list[i] = account;
        else list.Add(account);
        Save(list);
    }

    public void Remove(AccountKey key) => Save(All.Where(a => a.Key != key).ToList());

    List<SavedAccount> Load()
    {
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch (FileNotFoundException) { return []; }
        catch (DirectoryNotFoundException) { return []; }
        try
        {
            var json = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
            if (JsonNode.Parse(json) is not JsonObject { } root || root["accounts"] is not JsonArray list)
                throw new InvalidDataException("no account list");
            return list.Select(Parse).ToList();
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException or InvalidDataException)
        {
            // another Windows user's file or a damaged one: keep it aside and start over
            Log.Write($"accounts: {Path.GetFileName(path)} unreadable ({ex.GetType().Name}), moved to .bad");
            File.Move(path, path + ".bad", overwrite: true);
            return [];
        }
    }

    void Save(List<SavedAccount> list)
    {
        var root = new JsonObject { ["version"] = 1, ["accounts"] = new JsonArray(list.Select(Entry).ToArray()) };
        var data = ProtectedData.Protect(Encoding.UTF8.GetBytes(root.ToJsonString()), Entropy, DataProtectionScope.CurrentUser);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, overwrite: true);
        accounts = list;
    }

    static JsonNode Entry(SavedAccount a) => new JsonObject
    {
        ["savedAt"] = a.SavedAt.ToString("O", CultureInfo.InvariantCulture),
        ["claudeAiOauth"] = a.Login.Oauth.DeepClone(),
        ["oauthAccount"] = a.Login.Account.DeepClone(),
    };

    static SavedAccount Parse(JsonNode? entry)
    {
        if (entry is JsonObject o
            && o["claudeAiOauth"] is JsonObject oauth
            && o["oauthAccount"] is JsonObject account
            && o["savedAt"] is JsonValue saved && saved.TryGetValue<string>(out var text)
            && DateTimeOffset.TryParseExact(text, "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out var at))
            return new SavedAccount(new AccountLogin(oauth, account), at);
        throw new InvalidDataException("unreadable account entry");
    }
}
