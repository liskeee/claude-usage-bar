using System.Drawing.Drawing2D;

namespace ClaudeUsageBar.UI;

/// Drawing helpers shared by the taskbar readout and the details popup.
public static class Primitives
{
    // Claude spark: 12 rounded rays of uneven length, clockwise from 12 o'clock
    static readonly float[] RayLength = [1.0f, 0.74f, 0.9f, 0.8f, 1.0f, 0.72f, 0.94f, 0.78f, 0.98f, 0.76f, 0.88f, 0.82f];

    public static void Spark(Graphics g, float cx, float cy, float r, Color color)
    {
        using var pen = new Pen(color, r * 0.24f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        for (int i = 0; i < RayLength.Length; i++)
        {
            double angle = (-90 + i * 30) * Math.PI / 180;
            float r0 = r * 0.22f, r1 = r * RayLength[i];
            g.DrawLine(pen,
                cx + (float)Math.Cos(angle) * r0, cy + (float)Math.Sin(angle) * r0,
                cx + (float)Math.Cos(angle) * r1, cy + (float)Math.Sin(angle) * r1);
        }
    }

    public static void Pill(Graphics g, Color color, float x, float y, float w, float h)
    {
        using var path = new GraphicsPath();
        path.AddArc(x, y, h, h, 90, 180);
        path.AddArc(x + w - h, y, h, h, 270, 180);
        path.CloseFigure();
        using var brush = new SolidBrush(color);
        g.FillPath(brush, path);
    }

    public static float Measure(Graphics g, string text, Font font) =>
        g.MeasureString(text, font, PointF.Empty, StringFormat.GenericTypographic).Width;

    /// Draws text with its baseline at `baseline`; returns the x where the text ends.
    public static float Text(Graphics g, string text, Font font, Color color, float x, float baseline)
    {
        var family = font.FontFamily;
        float ascent = font.Size * family.GetCellAscent(font.Style) / family.GetEmHeight(font.Style);
        using var brush = new SolidBrush(color);
        g.DrawString(text, font, brush, x, baseline - ascent, StringFormat.GenericTypographic);
        return x + Measure(g, text, font);
    }
}
