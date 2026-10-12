import AppKit
import ClaudeUsageBarCore

/// Wires the service, the readout, the menu and the timers together.
@MainActor final class AppController {
    let paths: AppPaths
    let texts: Texts
    let service: UsageService
    let status: StatusItemController
    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    init() {
        // locals first: a class can't read its own properties before they are all set
        let paths = AppPaths.standard()
        Log.configure(directory: paths.logs)
        let texts = Self.loadTexts()
        let runner = SystemProcessRunner()
        let keychain = SecurityCLI(runner: runner)
        self.paths = paths
        self.texts = texts
        service = UsageService(
            credentials: KeychainCredentialStore(keychain: keychain),
            api: HTTPUsageAPI(version: Self.version),
            renewer: CliTokenRenewer.standard(runner: runner, workDir: paths.renewDir, cliLock: AsyncLock()),
            time: SystemTime())
        status = StatusItemController(texts: texts)
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
        service.onChange = { [weak self] state in self?.status.bar.state = state }
        status.onRightClick = { [weak self] in self?.showMenu() }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        refreshNow()
    }

    func tick() { status.bar.tick() }

    func refreshNow() {
        refreshTimer?.invalidate()
        Task {
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

    func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(texts.menu.refreshNow) { [weak self] in self?.refreshNow() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.macos.menu.quit) { NSApp.terminate(nil) })
        status.showMenu(menu)
    }
}
