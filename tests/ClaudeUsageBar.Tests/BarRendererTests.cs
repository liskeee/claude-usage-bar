using System.Drawing.Imaging;
using ClaudeUsageBar.Core;
using ClaudeUsageBar.UI;

namespace ClaudeUsageBar.Tests;

public class BarRendererTests
{
    static readonly DateTimeOffset Now = new(2026, 10, 1, 14, 0, 0, TimeSpan.FromHours(2));
    static readonly Size BarSize = new(BarRenderer.LogicalWidth, 48);

    static UsageState StateWith(double session, double week, DateTimeOffset? lastSuccess = null) =>
        new(ServiceStatus.Ok,
            new UsageSnapshot(
            [
                new LimitInfo(LimitKind.Session, "Current session", session, Now.AddHours(4)),
                new LimitInfo(LimitKind.Weekly, "This week", week, Now.AddDays(6)),
            ], Now),
            "Max 20x", lastSuccess ?? Now, null);

    static Bitmap Render(UsageState state)
    {
        var bmp = new Bitmap(BarSize.Width, BarSize.Height, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        BarRenderer.Draw(g, BarSize, 1f, state, Now, Theme.Dark);
        return bmp;
    }

    // inside the left end of each bar at 100% scale: session bar y=13..18, week bar y=30..35, both start at x=45
    static int SessionBar(Bitmap bmp) => bmp.GetPixel(47, 15).ToArgb();
    static int WeekBar(Bitmap bmp) => bmp.GetPixel(47, 32).ToArgb();

    [Fact]
    public void LowUsage_PaintsGreenBars()
    {
        using var bmp = Render(StateWith(26, 22));
        Assert.Equal(Theme.Dark.Ok.ToArgb(), SessionBar(bmp));
        Assert.Equal(Theme.Dark.Ok.ToArgb(), WeekBar(bmp));
    }

    [Fact]
    public void Thresholds_ColorEachBarSeparately()
    {
        using var bmp = Render(StateWith(86, 61));
        Assert.Equal(Theme.Dark.Critical.ToArgb(), SessionBar(bmp));
        Assert.Equal(Theme.Dark.Warn.ToArgb(), WeekBar(bmp));
    }

    [Fact]
    public void StaleData_IsGreyedOut()
    {
        using var bmp = Render(StateWith(26, 22, lastSuccess: Now.AddMinutes(-20)));
        Assert.NotEqual(Theme.Dark.Ok.ToArgb(), SessionBar(bmp));
    }

    [Fact]
    public void NeedsLogin_DrawsNoBars()
    {
        using var bmp = Render(UsageState.Initial with { Status = ServiceStatus.NeedsLogin });
        Assert.True(bmp.GetPixel(47, 15).A < 10);
    }

    [Fact]
    public void Loading_DrawsEmptyTracks()
    {
        using var bmp = Render(UsageState.Initial);
        Assert.NotEqual(Theme.Dark.Ok.ToArgb(), SessionBar(bmp));
        Assert.True(bmp.GetPixel(47, 15).A > 10); // the empty track is still visible
    }

    [Fact]
    public void Background_IsAlmostTransparent_ButClickable()
    {
        using var bmp = Render(StateWith(26, 22));
        Assert.Equal(1, bmp.GetPixel(BarSize.Width - 1, 0).A);
    }
}
