using System.Net;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class HttpUsageApiTests
{
    sealed class StubHandler(HttpStatusCode code, string body = "{}") : HttpMessageHandler
    {
        public HttpRequestMessage? Last { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Last = request;
            return Task.FromResult(new HttpResponseMessage(code) { Content = new StringContent(body) });
        }
    }

    sealed class OfflineHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            throw new HttpRequestException("No such host is known.");
    }

    [Fact]
    public async Task Ok_ReturnsBody_AndSendsAuthHeaders()
    {
        var handler = new StubHandler(HttpStatusCode.OK, """{"limits":[]}""");

        var result = await new HttpUsageApi(new HttpClient(handler)).FetchAsync("test-token", default);

        Assert.Equal(ApiStatus.Ok, result.Status);
        Assert.Equal("""{"limits":[]}""", result.Json);
        Assert.Equal("https://api.anthropic.com/api/oauth/usage", handler.Last!.RequestUri!.ToString());
        Assert.Equal("Bearer test-token", handler.Last.Headers.Authorization!.ToString());
        Assert.Equal("oauth-2025-04-20", handler.Last.Headers.GetValues("anthropic-beta").Single());
    }

    [Fact]
    public async Task Status401_IsUnauthorized()
    {
        var result = await new HttpUsageApi(new HttpClient(new StubHandler(HttpStatusCode.Unauthorized))).FetchAsync("t", default);
        Assert.Equal(ApiStatus.Unauthorized, result.Status);
    }

    [Fact]
    public async Task Status429_IsRateLimited()
    {
        var result = await new HttpUsageApi(new HttpClient(new StubHandler(HttpStatusCode.TooManyRequests))).FetchAsync("t", default);
        Assert.Equal(new UsageApiResult(ApiStatus.RateLimited, Error: "HTTP 429"), result);
    }

    [Fact]
    public async Task ServerError_IsFailedWithStatusCode()
    {
        var result = await new HttpUsageApi(new HttpClient(new StubHandler(HttpStatusCode.ServiceUnavailable))).FetchAsync("t", default);
        Assert.Equal(new UsageApiResult(ApiStatus.Failed, Error: "HTTP 503"), result);
    }

    [Fact]
    public async Task NetworkError_IsFailedWithMessage()
    {
        var result = await new HttpUsageApi(new HttpClient(new OfflineHandler())).FetchAsync("t", default);
        Assert.Equal(new UsageApiResult(ApiStatus.Failed, Error: "No such host is known."), result);
    }
}
