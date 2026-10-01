using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.UI;

/// Flyout with all limits and reset times; opens above the readout and closes when it loses focus.
public sealed class DetailsPopup : Form
{
    readonly Texts texts;
    UsageState state = UsageState.Initial;

    public event Action? RefreshRequested;

    /// Environment.TickCount64 of the last hide; lets a click on the readout close the popup instead of reopening it.
    public long HiddenAtTicks { get; private set; }

    public DetailsPopup(Texts texts)
    {
        this.texts = texts;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        DoubleBuffered = true;
        KeyPreview = true;
        Text = "ClaudeUsageBar";
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WS_EX_TOOLWINDOW;
            cp.ClassStyle |= Native.CS_DROPSHADOW;
            return cp;
        }
    }

    float S => DeviceDpi / 96f;

    public void SetState(UsageState newState)
    {
        state = newState;
        if (!Visible) return;
        var bottom = Bottom;
        Height = (int)Math.Round(DetailsRenderer.LogicalHeight(state) * S);
        Top = bottom - Height;
        Invalidate();
    }

    /// Opens right-aligned above `anchor` (the readout's screen bounds).
    public void ShowAbove(Rectangle anchor)
    {
        _ = Handle; // create the window first so DeviceDpi is known
        Native.StylePopup(Handle, Theme.Current.Border);
        var size = new Size((int)Math.Round(DetailsRenderer.LogicalWidth * S), (int)Math.Round(DetailsRenderer.LogicalHeight(state) * S));
        var screen = Screen.FromRectangle(anchor).Bounds;
        int x = Math.Clamp(anchor.Right - size.Width, screen.Left + 8, screen.Right - size.Width - 8);
        Bounds = new Rectangle(new Point(x, anchor.Top - size.Height - (int)Math.Round(8 * S)), size);
        Show();
        Activate();
    }

    void HideNow()
    {
        Hide();
        HiddenAtTicks = Environment.TickCount64;
    }

    protected override void OnDeactivate(EventArgs e)
    {
        base.OnDeactivate(e);
        HideNow();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.KeyCode == Keys.Escape) HideNow();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        Cursor = OverRefresh(e.Location) ? Cursors.Hand : Cursors.Default;
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button == MouseButtons.Left && OverRefresh(e.Location)) RefreshRequested?.Invoke();
    }

    bool OverRefresh(Point p) => DetailsRenderer.RefreshRect(ClientSize, S).Contains(p);

    protected override void OnPaint(PaintEventArgs e) =>
        DetailsRenderer.Draw(e.Graphics, ClientSize, S, state, DateTimeOffset.Now, Theme.Current, texts);
}
