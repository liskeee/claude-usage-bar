using System.Drawing.Drawing2D;
using System.Drawing.Text;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.UI;

/// Layout and drawing of the details popup: one block per limit, footer with status and the refresh link.
public static class DetailsRenderer
{
    public const int LogicalWidth = 300;
    const int Pad = 16, HeaderHeight = 44, BlockHeight = 58, FooterHeight = 44, LinkWidth = 64;

    public static int LogicalHeight(UsageState state) =>
        HeaderHeight + Math.Max(1, state.Snapshot?.Limits.Count ?? 0) * BlockHeight + FooterHeight;

    /// Hit area of the refresh link, in device pixels.
    public static RectangleF RefreshRect(Size size, float s) =>
        new(size.Width - (LinkWidth + Pad) * s, size.Height - FooterHeight * s, (LinkWidth + Pad) * s, FooterHeight * s);

    public static string FooterText(UsageState state, DateTimeOffset now, Texts texts) => state.Status switch
    {
        ServiceStatus.Ok when state.LastSuccess is { } t => Texts.Fill(texts.Popup.Updated, ("ago", Format.Ago(now - t, texts))),
        ServiceStatus.Error when state.LastSuccess is { } t => Texts.Fill(texts.Popup.RefreshFailed, ("ago", Format.Ago(now - t, texts))),
        ServiceStatus.Error => texts.Popup.LoadFailed,
        ServiceStatus.NeedsLogin => texts.Popup.SignIn,
        _ => texts.Popup.Loading,
    };

    public static string ResetText(DateTimeOffset reset, DateTimeOffset now, Texts texts) =>
        Texts.Fill(texts.Popup.ResetLine,
            ("countdown", Format.CountdownLong(reset - now, texts)),
            ("moment", Format.ResetMoment(reset.LocalDateTime, now.LocalDateTime, texts)));

    /// Body text when there is no snapshot to show yet.
    public static string EmptyText(UsageState state, Texts texts) => state.Status switch
    {
        ServiceStatus.NeedsLogin => texts.Popup.EmptyNeedsLogin,
        ServiceStatus.Error => texts.Popup.EmptyError,
        _ => texts.Popup.EmptyLoading,
    };

    public static void Draw(Graphics g, Size size, float s, UsageState state, DateTimeOffset now, Palette p, Texts texts)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        g.Clear(p.Surface);
        using var title = new Font("Segoe UI Semibold", 14 * s, GraphicsUnit.Pixel);
        using var label = new Font("Segoe UI", 12 * s, GraphicsUnit.Pixel);
        using var value = new Font("Segoe UI Semibold", 12 * s, GraphicsUnit.Pixel);
        using var small = new Font("Segoe UI", 11 * s, GraphicsUnit.Pixel);
        float x = Pad * s, right = size.Width - Pad * s;

        Primitives.Spark(g, x + 8 * s, 23 * s, 7 * s, p.Clay);
        var heading = string.IsNullOrEmpty(state.PlanName) ? "Claude" : $"Claude {state.PlanName}";
        Primitives.Text(g, heading, title, p.Text, x + 22 * s, 28 * s);

        float y = HeaderHeight * s;
        var limits = state.Snapshot?.Limits ?? Array.Empty<LimitInfo>();
        if (limits.Count == 0)
            Primitives.Text(g, EmptyText(state, texts), label, p.Muted, x, y + 20 * s);
        foreach (var limit in limits)
        {
            Primitives.Text(g, Format.LimitLabel(limit, texts), label, p.Text, x, y + 14 * s);
            var percent = Format.Percent(limit.UsedPercent);
            Primitives.Text(g, percent, value, Theme.NumberColor(p, limit.UsedPercent), right - Primitives.Measure(g, percent, value), y + 14 * s);
            float barW = right - x, barH = 6 * s, barY = y + 21 * s;
            Primitives.Pill(g, p.Track, x, barY, barW, barH);
            Primitives.Pill(g, Theme.SeverityColor(p, limit.UsedPercent), x, barY,
                Math.Max(barH, barW * (float)Math.Clamp(limit.UsedPercent, 0, 100) / 100), barH);
            if (limit.ResetsAt is { } reset)
                Primitives.Text(g, ResetText(reset, now, texts), small, p.Muted, x, y + 44 * s);
            y += BlockHeight * s;
        }

        float footerY = size.Height - FooterHeight * s;
        using (var pen = new Pen(p.Border, Math.Max(1, s))) g.DrawLine(pen, x, footerY, right, footerY);
        Primitives.Text(g, FooterText(state, now, texts), small, p.Muted, x, footerY + 27 * s);
        var link = texts.Popup.Refresh;
        Primitives.Text(g, link, small, p.Accent, right - Primitives.Measure(g, link, small), footerY + 27 * s);
    }
}
