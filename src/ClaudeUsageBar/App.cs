using ClaudeUsageBar.Core;
using ClaudeUsageBar.UI;
using Microsoft.Win32;

namespace ClaudeUsageBar;

/// Wires the service, the taskbar readout, the popup, the menu and the timers together.
public sealed class App : ApplicationContext
{
    readonly UsageService service;
    readonly Texts texts;
    readonly TaskbarWindow bar;
    readonly DetailsPopup popup;
    readonly ContextMenuStrip menu = new();
    readonly BroadcastWindow broadcast = new();
    readonly System.Windows.Forms.Timer dockTimer = new() { Interval = 2_000 };
    readonly System.Windows.Forms.Timer tickTimer = new() { Interval = 30_000 };
    readonly System.Windows.Forms.Timer refreshTimer = new();

    public App(UsageService service, Texts texts)
    {
        this.service = service;
        this.texts = texts;
        bar = new TaskbarWindow(service.State, texts);
        popup = new DetailsPopup(texts);
        service.Changed += state =>
        {
            bar.SetState(state);
            popup.SetState(state);
        };

        bar.LeftClick += TogglePopup;
        bar.RightClick += () => menu.Show(Cursor.Position);
        popup.RefreshRequested += () => _ = RefreshNowAsync();
        BuildMenu();

        dockTimer.Tick += (_, _) => { if (bar.IsAttached) bar.Reposition(); else bar.Attach(); };
        tickTimer.Tick += (_, _) => { bar.Render(); if (popup.Visible) popup.Invalidate(); };
        refreshTimer.Tick += (_, _) => _ = RefreshNowAsync();
        broadcast.TaskbarCreated += bar.Attach;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        bar.Attach();
        dockTimer.Start();
        tickTimer.Start();
        _ = RefreshNowAsync();
    }

    void BuildMenu()
    {
        var autostart = new ToolStripMenuItem(texts.Menu.StartWithWindows);
        autostart.Click += (_, _) => ToggleAutostart();
        menu.Items.Add(new ToolStripMenuItem(texts.Menu.RefreshNow, null, (_, _) => _ = RefreshNowAsync()));
        menu.Items.Add(autostart);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(texts.Menu.Exit, null, (_, _) => ExitThread()));
        menu.Opening += (_, _) => autostart.Checked = Autostart.IsEnabled;
    }

    async Task RefreshNowAsync()
    {
        refreshTimer.Stop();
        try { await service.RefreshAsync(); }
        catch (Exception ex) { Log.Write($"refresh failed: {ex}"); }
        refreshTimer.Interval = (int)Math.Clamp(service.NextDelay().TotalMilliseconds, 1_000, int.MaxValue);
        refreshTimer.Start();
    }

    void TogglePopup()
    {
        if (popup.Visible) { popup.Hide(); return; }
        // clicking the readout first deactivates (and hides) an open popup; don't reopen it right away
        if (Environment.TickCount64 - popup.HiddenAtTicks < 300) return;
        popup.ShowAbove(bar.ScreenBounds);
    }

    void ToggleAutostart()
    {
        try
        {
            if (Autostart.IsEnabled) Autostart.Disable();
            else if (Environment.ProcessPath is { } exe) Autostart.Enable(exe, texts.AutostartDescription);
        }
        catch (Exception ex) { Log.Write($"autostart toggle failed: {ex.Message}"); }
    }

    void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume) _ = RefreshNowAsync();
    }

    void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e) => bar.Render(); // light/dark switch

    protected override void ExitThreadCore()
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        dockTimer.Dispose();
        tickTimer.Dispose();
        refreshTimer.Dispose();
        bar.Dispose();
        popup.Dispose();
        menu.Dispose();
        broadcast.DestroyHandle();
        base.ExitThreadCore();
    }
}

/// Hidden top-level window: only top-level windows receive "TaskbarCreated" after Explorer restarts.
sealed class BroadcastWindow : NativeWindow
{
    static readonly int TaskbarCreatedMessage = (int)Native.RegisterWindowMessage("TaskbarCreated");

    public event Action? TaskbarCreated;

    public BroadcastWindow() => CreateHandle(new CreateParams { Caption = "ClaudeUsageBar.Broadcast" });

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == TaskbarCreatedMessage)
        {
            Log.Write("TaskbarCreated received");
            TaskbarCreated?.Invoke();
        }
        base.WndProc(ref m);
    }
}
