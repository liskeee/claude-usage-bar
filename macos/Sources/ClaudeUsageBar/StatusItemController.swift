import AppKit
import ClaudeUsageBarCore

/// The menu bar item: the readout is the button's content; left click → popover, right click or ctrl+click → menu.
@MainActor final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: BarView.width)
    let bar: BarView
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    init(texts: Texts) {
        bar = BarView(texts: texts)
        super.init()
        guard let button = item.button else { return }
        bar.frame = NSRect(x: 0, y: 0, width: BarView.width, height: NSStatusBar.system.thickness)
        bar.autoresizingMask = [.width, .height]
        button.addSubview(bar)
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    /// Shows `menu` attached to the item, the way a status item's own menu opens.
    func showMenu(_ menu: NSMenu) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
