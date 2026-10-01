using System.Drawing.Drawing2D;
using System.Drawing.Text;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.UI;

/// The two-row taskbar readout: "5h ▰▱ 38% 3h 49m" over "W ▰▱ 24% 6d 17h".
public static class BarRenderer
{
    public const int LogicalWidth = 160;

    public static void Draw(Graphics g, Size size, float s, UsageState state, DateTimeOffset now, Palette p)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.Clear(Color.FromArgb(1, 0, 0, 0)); // alpha 1: invisible, but the layered window still receives clicks
        float cy = size.Height / 2f;
        Primitives.Spark(g, 11 * s, cy, 8.5f * s, p.Clay);

        if (state.Status == ServiceStatus.NeedsLogin)
        {
            using var message = new Font("Segoe UI", 12 * s, GraphicsUnit.Pixel);
            Primitives.Text(g, "Claude: sign in", message, p.Muted, 27 * s, cy + 4 * s);
            return;
        }

        using var label = new Font("Segoe UI", 11 * s, GraphicsUnit.Pixel);
        using var number = new Font("Segoe UI Semibold", 12.5f * s, GraphicsUnit.Pixel);
        bool stale = state.LastSuccess is not { } last || now - last > UsageService.StaleAfter;
        Row(g, p, label, number, stale, 27 * s, cy - 4 * s, "5h", state.Snapshot?.Session, now, s);
        Row(g, p, label, number, stale, 27 * s, cy + 13 * s, "W", state.Snapshot?.Weekly, now, s);
    }

    static void Row(Graphics g, Palette p, Font label, Font number, bool stale, float x, float baseline,
        string name, LimitInfo? limit, DateTimeOffset now, float s)
    {
        Primitives.Text(g, name, label, p.Muted, x, baseline);
        float barX = x + 18 * s, barW = 36 * s, barH = 5 * s, barY = baseline - 4.5f * s - barH / 2;
        float numberRight = barX + barW + 32 * s;
        Primitives.Pill(g, p.Track, barX, barY, barW, barH);
        if (limit is null)
        {
            Primitives.Text(g, "…", number, p.Muted, numberRight - Primitives.Measure(g, "…", number), baseline);
            return;
        }

        var fill = stale ? p.Muted : Theme.SeverityColor(p, limit.UsedPercent);
        Primitives.Pill(g, fill, barX, barY, Math.Max(barH, barW * (float)Math.Clamp(limit.UsedPercent, 0, 100) / 100), barH);
        var text = Format.Percent(limit.UsedPercent);
        var textColor = stale ? p.Muted : Theme.NumberColor(p, limit.UsedPercent);
        Primitives.Text(g, text, number, textColor, numberRight - Primitives.Measure(g, text, number), baseline);
        if (limit.ResetsAt is { } reset)
            Primitives.Text(g, Format.CountdownShort(reset - now), label, p.Muted, numberRight + 7 * s, baseline);
    }
}
