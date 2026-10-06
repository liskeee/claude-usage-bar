using ClaudeUsageBar.Core;
using ClaudeUsageBar.UI;
using Microsoft.Win32;

namespace ClaudeUsageBar;

/// Wires the service, the accounts, the taskbar readout, the popup, the menu and the timers together.
public sealed class App : ApplicationContext
{
    const string Caption = "ClaudeUsageBar";

    readonly UsageService service;
    readonly AccountSwitcher accounts;
    readonly Texts texts;
    readonly TaskbarWindow bar;
    readonly DetailsPopup popup;
    readonly ContextMenuStrip menu = new();
    readonly List<ToolStripItem> accountItems = [];
    readonly BroadcastWindow broadcast = new();
    readonly CancellationTokenSource exiting = new();
    readonly System.Windows.Forms.Timer dockTimer = new() { Interval = 2_000 };
    readonly System.Windows.Forms.Timer tickTimer = new() { Interval = 30_000 };
    readonly System.Windows.Forms.Timer refreshTimer = new();

    public App(UsageService service, AccountSwitcher accounts, Texts texts)
    {
        this.service = service;
        this.accounts = accounts;
        this.texts = texts;
        bar = new TaskbarWindow(service.State, texts);
        popup = new DetailsPopup(texts);
        service.Changed += state =>
        {
            bar.SetState(state);
            popup.SetState(state);
        };
        accounts.Switched += () =>
        {
            service.Reset(); // the previous account's numbers must never show under the new one
            _ = RefreshNowAsync();
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
        menu.Opening += (_, _) =>
        {
            autostart.Checked = Autostart.IsEnabled;
            RebuildAccountItems();
        };
    }

    /// Accounts sit at the top of the menu, so switching takes two clicks.
    void RebuildAccountItems()
    {
        foreach (var item in accountItems)
        {
            menu.Items.Remove(item);
            item.Dispose();
        }
        accountItems.Clear();
        SyncAccounts();

        IReadOnlyList<SavedAccount> all;
        try { all = AccountLabels.Ordered(accounts.Accounts); }
        catch (IOException ex) { Log.Write($"accounts: can't read the list: {ex.Message}"); all = []; }
        var now = DateTimeOffset.UtcNow;
        var activeKey = accounts.Active?.Key;

        foreach (var account in all)
        {
            bool active = account.Key == activeKey;
            // the active account also needs a new login when its tokens turned out to be revoked
            bool needsSignIn = AccountLabels.NeedsSignIn(account, now) || (active && service.State.Status == ServiceStatus.NeedsLogin);
            var item = new ToolStripMenuItem(AccountLabels.ForMenu(AccountLabels.MenuText(account, all, needsSignIn, texts))) { Checked = active };
            if (needsSignIn)
                item.Click += (_, _) => RunAccountAction(() => accounts.AddAccountAsync(account.Login.Email, exiting.Token));
            else if (!active)
                item.Click += (_, _) => RunAccountAction(() => accounts.SwitchToAsync(account.Key, exiting.Token));
            accountItems.Add(item);
        }

        accountItems.Add(new ToolStripMenuItem(texts.Accounts.Add, null, (_, _) => RunAccountAction(() => accounts.AddAccountAsync(null, exiting.Token)))
        {
            Enabled = !accounts.IsLoginRunning,
        });

        var removable = all.Where(a => a.Key != activeKey).ToList();
        if (removable.Count > 0)
        {
            var remove = new ToolStripMenuItem(texts.Accounts.Remove);
            foreach (var account in removable)
                remove.DropDownItems.Add(new ToolStripMenuItem(AccountLabels.ForMenu(AccountLabels.Label(account, all)), null, (_, _) => ConfirmRemove(account, all)));
            accountItems.Add(remove);
        }

        accountItems.Add(new ToolStripSeparator());
        for (int i = 0; i < accountItems.Count; i++) menu.Items.Insert(i, accountItems[i]);
    }

    void ConfirmRemove(SavedAccount account, IReadOnlyList<SavedAccount> all)
    {
        var question = Texts.Fill(texts.Accounts.RemoveConfirm, ("account", AccountLabels.Label(account, all)));
        if (MessageBox.Show(question, Caption, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        try { accounts.Remove(account.Key); }
        catch (Exception ex) { Log.Write($"accounts: remove failed: {ex.Message}"); }
    }

    /// Runs an account action from the menu; a failure is explained in a message box (nothing was changed).
    async void RunAccountAction(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { } // the app is exiting
        catch (AccountException ex)
        {
            Log.Write($"accounts: {ex.Error}: {ex.Message}");
            ShowError(ex.Error switch
            {
                AccountError.ClaudeNotFound => texts.Accounts.ClaudeNotFound,
                AccountError.LoginFailed => texts.Accounts.LoginFailed,
                _ => texts.Accounts.WriteFailed,
            });
        }
        catch (Exception ex)
        {
            Log.Write($"accounts: {ex}");
            ShowError(texts.Accounts.WriteFailed);
        }
    }

    static void ShowError(string text) => MessageBox.Show(text, Caption, MessageBoxButtons.OK, MessageBoxIcon.Warning);

    /// Saves the active login if it is new or its tokens rotated, and shows its e-mail in the popup.
    void SyncAccounts()
    {
        try { accounts.Sync(); }
        catch (Exception ex) { Log.Write($"accounts: sync failed: {ex.Message}"); }
        popup.SetAccount(accounts.Active?.Email);
    }

    async Task RefreshNowAsync()
    {
        refreshTimer.Stop();
        SyncAccounts();
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
        exiting.Cancel(); // closes a running add-account login window
        exiting.Dispose();
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
