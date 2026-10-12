import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            // already running, e.g. started at login and again by hand
            NSApp.terminate(nil)
            return
        }
        let controller = AppController()
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
}
