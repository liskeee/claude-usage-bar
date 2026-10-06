using ClaudeUsageBar.UI;

namespace ClaudeUsageBar.Tests;

public sealed class PrimitivesTests : IDisposable
{
    readonly Bitmap bmp = new(1, 1);
    readonly Graphics g;
    readonly Font font = new("Segoe UI", 11, GraphicsUnit.Pixel);

    public PrimitivesTests() => g = Graphics.FromImage(bmp);

    public void Dispose()
    {
        g.Dispose();
        bmp.Dispose();
        font.Dispose();
    }

    [Fact]
    public void Ellipsize_FittingText_IsUnchanged() =>
        Assert.Equal("a@b.pl", Primitives.Ellipsize(g, "a@b.pl", font, 200));

    [Fact]
    public void Ellipsize_LongText_IsCutWithAnEllipsisToFit()
    {
        const string text = "very.long.address.of.someone@a-company-with-a-long-name.example.com";

        var cut = Primitives.Ellipsize(g, text, font, 120);

        Assert.EndsWith("…", cut);
        Assert.StartsWith(cut[..^1], text);
        Assert.True(Primitives.Measure(g, cut, font) <= 120);
    }

    [Theory]
    [InlineData(2)]
    [InlineData(-30)] // heading wider than the popup leaves negative room
    public void Ellipsize_NoRoom_IsEmpty(float width) =>
        Assert.Equal("", Primitives.Ellipsize(g, "abc@x.pl", font, width));
}
