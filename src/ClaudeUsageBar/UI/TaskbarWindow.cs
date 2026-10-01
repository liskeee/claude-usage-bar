using System.Drawing.Imaging;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.UI;

/// The readout: a layered child window inside the taskbar, just left of the notification area.
/// A plain WinForms Form gets re-parented to WinForms' hidden parking window, so this is a NativeWindow.
public sealed class TaskbarWindow(UsageState initial) : NativeWindow, IDisposable
{
    UsageState state = initial;
    IntPtr taskbar;
    Rectangle bounds;

    public event Action? LeftClick;
    public event Action? RightClick;

    public bool IsAttached => Handle != IntPtr.Zero && Native.IsWindow(taskbar) && Native.GetParent(Handle) == taskbar;

    /// Bounds on screen, used to anchor the details popup.
    public Rectangle ScreenBounds => Native.GetWindowRect(Handle, out var r) ? r.ToRectangle() : Rectangle.Empty;

    /// Creates the window inside the current taskbar; also used after Explorer restarts.
    public void Attach()
    {
        var found = Native.FindWindow("Shell_TrayWnd", null);
        if (found == IntPtr.Zero) return;
        if (Handle != IntPtr.Zero) DestroyHandle();
        taskbar = found;
        bounds = Rectangle.Empty;
        CreateHandle(new CreateParams
        {
            Caption = "ClaudeUsageBar",
            Style = Native.WS_CHILD | Native.WS_VISIBLE | Native.WS_CLIPSIBLINGS,
            ExStyle = Native.WS_EX_LAYERED,
            Parent = taskbar,
        });
        Log.Write($"attached to taskbar 0x{taskbar:X}");
        Reposition();
    }

    /// Follows the tray (it widens and narrows as icons come and go) and stays on top of the taskbar's own content.
    public void Reposition()
    {
        if (!IsAttached) return;
        var tray = Native.FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
        if (!Native.GetWindowRect(taskbar, out var tb) || !Native.GetWindowRect(tray, out var tr)) return;
        float s = Scale;
        int width = (int)Math.Round(BarRenderer.LogicalWidth * s);
        var next = new Rectangle(tr.Left - tb.Left - width - (int)Math.Round(6 * s), 0, width, tb.Bottom - tb.Top);
        Native.SetWindowPos(Handle, IntPtr.Zero /* HWND_TOP */, next.X, next.Y, next.Width, next.Height,
            Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
        if (next == bounds) return;
        bounds = next;
        Render();
    }

    public void SetState(UsageState newState)
    {
        state = newState;
        Render();
    }

    public void Render()
    {
        if (!IsAttached || bounds.Width <= 0 || bounds.Height <= 0) return;
        using var bitmap = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
            BarRenderer.Draw(g, bitmap.Size, Scale, state, DateTimeOffset.Now, Theme.Current);
        Native.UpdateLayered(Handle, bitmap);
    }

    // the taskbar's own DPI, so the readout matches it even if our DPI context differs from Explorer's
    float Scale => Native.GetDpiForWindow(taskbar) is var dpi and > 0 ? dpi / 96f : 1f;

    protected override void WndProc(ref Message m)
    {
        switch (m.Msg)
        {
            case Native.WM_LBUTTONUP: LeftClick?.Invoke(); return;
            case Native.WM_RBUTTONUP: RightClick?.Invoke(); return;
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        if (Handle != IntPtr.Zero) DestroyHandle();
    }
}
