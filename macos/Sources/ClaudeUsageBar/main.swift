import AppKit

// tools/package.sh renders the app icon with the same spark code as the menu bar
if let index = CommandLine.arguments.firstIndex(of: "--render-icon"), index + 1 < CommandLine.arguments.count {
    do {
        try Spark.renderIconset(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-icon: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
