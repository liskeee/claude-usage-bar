import AppKit
import ClaudeUsageBarCore
import SwiftUI

/// Wires the service, the readout, the popover, the menu and the timers together.
@MainActor final class AppController: NSObject, NSPopoverDelegate {
    let paths: AppPaths
    let texts: Texts
    let service: UsageService
    let status: StatusItemController
    let details: DetailsModel
    let popover = NSPopover()
    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    override init() {
        // locals first: a class can't read its own properties before super.init
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
        service.onChange = { [weak self] state in
            self?.status.bar.state = state
            self?.details.state = state
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

    func tick() {
        status.bar.tick()
        if popover.isShown { details.now = Date() }
    }

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
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(texts.menu.refreshNow) { [weak self] in self?.refreshNow() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.macos.menu.quit) { NSApp.terminate(nil) })
        status.showMenu(menu)
    }
}
