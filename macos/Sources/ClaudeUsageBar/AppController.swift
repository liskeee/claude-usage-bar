import AppKit
import ClaudeUsageBarCore
import SwiftUI

/// Wires the service, the accounts, the readout, the popover, the menu and the timers together.
@MainActor final class AppController: NSObject, NSPopoverDelegate {
    let paths: AppPaths
    let texts: Texts
    let service: UsageService
    let switcher: AccountSwitcher
    let status: StatusItemController
    let details: DetailsModel
    let popover = NSPopover()
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var syncingForRefresh = false // a hand switch found by the refresh's own sync needs no second refresh

    override init() {
        // locals first: a class can't read its own properties before super.init
        let paths = AppPaths.standard()
        Log.configure(directory: paths.logs)
        let texts = Self.loadTexts()
        let runner = SystemProcessRunner()
        let keychain = SecurityCLI(runner: runner)
        let accountsKey = AccountsKey(keychain: keychain)
        let cliLock = AsyncLock() // shared: a token renewal never runs during a switch
        self.paths = paths
        self.texts = texts
        service = UsageService(
            credentials: KeychainCredentialStore(keychain: keychain),
            api: HTTPUsageAPI(version: Self.version),
            renewer: CliTokenRenewer.standard(runner: runner, workDir: paths.renewDir, cliLock: cliLock),
            time: SystemTime())
        switcher = AccountSwitcher(
            cli: CliLogin.standard(keychain: keychain, paths: paths, sealBackup: { data in try await accountsKey.seal(data) }),
            store: AccountStore(file: paths.accountsFile, key: accountsKey),
            cliLock: cliLock,
            loginRoot: paths.support,
            loginFor: { dir in CliLogin.forConfigDir(dir, keychain: keychain) },
            runLogin: { email, dir in
                guard let claude = ClaudeCLI.findDefault() else { throw AccountError.claudeNotFound }
                let login = LoginRunner(claude: claude, hint: texts.accounts.loginHint, openTerminal: LoginRunner.terminal(runner: runner))
                return try await login.run(email: email, dir: dir)
            },
            time: SystemTime())
        status = StatusItemController(texts: texts)
        details = DetailsModel(texts: texts)
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: DetailsView(model: details))
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Translations ship inside the app; a missing file is a packaging bug, found at the first launch.
    static func loadTexts() -> Texts {
        let directory = Bundle.main.resourceURL!.appending(path: "localization")
        let code = Texts.languageCode(preferred: Locale.preferredLanguages, available: Texts.available(in: directory))
        do { return try Texts.load(code, from: directory) }
        catch { fatalError("translations missing from \(directory.path): \(error)") }
    }

    func start() {
        Log.write("start \(Self.version)")
        firstRun()
        service.onChange = { [weak self] state in
            self?.status.bar.state = state
            self?.details.state = state
        }
        switcher.onSwitched = { [weak self] in
            guard let self else { return }
            service.reset() // the previous account's numbers must never show under the new one
            details.account = switcher.active?.email
            if !syncingForRefresh { refreshNow() }
        }
        status.onLeftClick = { [weak self] in self?.togglePopover() }
        status.onRightClick = { [weak self] in self?.showMenu() }
        details.onRefresh = { [weak self] in self?.refreshNow() }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        refreshNow()
        if CommandLine.arguments.contains("--show-popover") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                togglePopover()
            }
        }
    }

    /// The first run turns on "Start at login", as the Windows app does with "Start with Windows".
    private func firstRun() {
        guard !FileManager.default.fileExists(atPath: paths.firstRunMarker.path) else { return }
        LoginItem.setEnabled(true)
        try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.firstRunMarker.path, contents: Data())
    }

    /// On quit: close a running add-account Terminal script (its login dir is cleaned up on the next add).
    func stop() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.support.path)) ?? []
        for name in names where name.hasPrefix("login-") {
            if let pid = LoginRunner.readInt(paths.support.appending(path: "\(name)/pid")) { kill(pid_t(pid), SIGHUP) }
        }
    }

    func tick() {
        status.bar.tick()
        if popover.isShown { details.now = Date() }
    }

    func refreshNow() {
        refreshTimer?.invalidate()
        Task {
            syncingForRefresh = true
            await switcher.sync()
            syncingForRefresh = false
            details.account = switcher.active?.email
            await service.refresh()
            scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(1, service.nextDelay()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = status.item.button else { return }
        details.now = Date()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        NSApp.activate()
    }

    func popoverDidClose(_ notification: Notification) { status.item.button?.highlight(false) }

    func showMenu() {
        Task {
            await switcher.sync()
            details.account = switcher.active?.email
            status.showMenu(await buildMenu())
        }
    }

    /// Accounts sit at the top of the menu, so switching takes two clicks.
    private func buildMenu() async -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all: [SavedAccount]
        do { all = AccountLabels.ordered(try await switcher.accounts()) }
        catch {
            Log.write("accounts: can't read the list: \(error)")
            all = []
        }
        let now = Date()
        let activeKey = switcher.active?.key
        for account in all {
            let active = account.key == activeKey
            // the active account also needs a new login when its tokens turned out to be revoked
            let needsSignIn = AccountLabels.needsSignIn(account, now: now) || (active && service.state.status == .needsLogin)
            let title = AccountLabels.menuText(account, among: all, needsSignIn: needsSignIn, texts)
            menu.addItem(ClosureMenuItem(title, checked: active) { [weak self] in
                guard let self else { return }
                if needsSignIn {
                    runAccountAction { try await self.switcher.addAccount(email: account.login.email) }
                } else if !active {
                    runAccountAction { try await self.switcher.switchTo(account.key) }
                }
            })
        }
        menu.addItem(ClosureMenuItem(texts.accounts.add, enabled: !switcher.isLoginRunning) { [weak self] in
            guard let self else { return }
            runAccountAction { try await self.switcher.addAccount(email: nil) }
        })
        let removable = all.filter { $0.key != activeKey }
        if !removable.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for account in removable {
                submenu.addItem(ClosureMenuItem(AccountLabels.label(account, among: all)) { [weak self] in
                    self?.confirmRemove(account, among: all)
                })
            }
            let remove = NSMenuItem(title: texts.accounts.remove, action: nil, keyEquivalent: "")
            remove.submenu = submenu
            menu.addItem(remove)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.menu.refreshNow) { [weak self] in self?.refreshNow() })
        menu.addItem(ClosureMenuItem(texts.macos.menu.startAtLogin, checked: LoginItem.isEnabled) { LoginItem.toggle() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.macos.menu.quit) { NSApp.terminate(nil) })
        return menu
    }

    /// Runs an account action from the menu; a failure is explained in an alert (nothing was changed).
    private func runAccountAction(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch is CancellationError {
                // the app is quitting
            } catch let error as AccountError {
                Log.write("accounts: \(error)")
                let text = switch error {
                case .claudeNotFound: texts.macos.accounts.claudeNotFound
                case .loginFailed: texts.accounts.loginFailed
                case .writeFailed: texts.accounts.writeFailed
                }
                showError(text)
            } catch {
                Log.write("accounts: \(error)")
                showError(texts.accounts.writeFailed)
            }
        }
    }

    private func confirmRemove(_ account: SavedAccount, among all: [SavedAccount]) {
        let alert = NSAlert()
        alert.messageText = Texts.fill(texts.accounts.removeConfirm, ("account", AccountLabels.label(account, among: all)))
        alert.addButton(withTitle: texts.macos.dialogs.remove)
        alert.addButton(withTitle: texts.macos.dialogs.cancel)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await switcher.remove(account.key) }
            catch { Log.write("accounts: remove failed: \(error)") }
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClaudeUsageBar"
        alert.informativeText = text
        alert.addButton(withTitle: texts.macos.dialogs.ok)
        NSApp.activate()
        alert.runModal()
    }
}
