using System.Net;
using System.Net.Http.Headers;

namespace ClaudeUsageBar.Core;

public enum ApiStatus { Ok, Unauthorized, RateLimited, Failed }

public sealed record UsageApiResult(ApiStatus Status, string? Json = null, string? Error = null);

public interface IUsageApi
{
    Task<UsageApiResult> FetchAsync(string accessToken, CancellationToken ct);
}

/// The same endpoint Claude Code's /usage uses.
public sealed class HttpUsageApi(HttpClient? http = null) : IUsageApi
{
    static readonly Uri Endpoint = new("https://api.anthropic.com/api/oauth/usage");
    readonly HttpClient http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

    public async Task<UsageApiResult> FetchAsync(string accessToken, CancellationToken ct)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            request.Headers.UserAgent.ParseAdd("ClaudeUsageBar/1.0");
            using var response = await http.SendAsync(request, ct);
            if (response.StatusCode == HttpStatusCode.Unauthorized) return new(ApiStatus.Unauthorized, Error: "HTTP 401");
            if (response.StatusCode == HttpStatusCode.TooManyRequests) return new(ApiStatus.RateLimited, Error: "HTTP 429");
            if (!response.IsSuccessStatusCode) return new(ApiStatus.Failed, Error: $"HTTP {(int)response.StatusCode}");
            return new(ApiStatus.Ok, Json: await response.Content.ReadAsStringAsync(ct));
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException) // TaskCanceled = timeout
        {
            return new(ApiStatus.Failed, Error: ex.Message);
        }
    }
}
