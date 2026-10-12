import AppKit
import ClaudeUsageBarCore

/// Colours for a light or dark menu bar and popover (the Windows palettes).
@MainActor struct Palette {
    let text, muted, track, ok, warn, critical, clay: NSColor

    static let dark = Palette(
        text: .white, muted: NSColor(white: 1, alpha: 0.65), track: NSColor(white: 1, alpha: 0.22),
        ok: NSColor(srgbRed: 108 / 255, green: 203 / 255, blue: 95 / 255, alpha: 1),
        warn: NSColor(srgbRed: 1, green: 185 / 255, blue: 0, alpha: 1),
        critical: NSColor(srgbRed: 1, green: 107 / 255, blue: 107 / 255, alpha: 1),
        clay: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1))

    static let light = Palette(
        text: NSColor(white: 0.1, alpha: 1), muted: NSColor(white: 0, alpha: 0.63), track: NSColor(white: 0, alpha: 0.16),
        ok: NSColor(srgbRed: 15 / 255, green: 123 / 255, blue: 15 / 255, alpha: 1),
        warn: NSColor(srgbRed: 157 / 255, green: 93 / 255, blue: 0, alpha: 1),
        critical: NSColor(srgbRed: 196 / 255, green: 43 / 255, blue: 28 / 255, alpha: 1),
        clay: NSColor(srgbRed: 193 / 255, green: 95 / 255, blue: 60 / 255, alpha: 1))

    static func current(_ appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    func severity(_ used: Double) -> NSColor {
        switch Format.severity(used) {
        case .ok: ok
        case .warn: warn
        case .critical: critical
        }
    }

    // numbers stay neutral for contrast until the limit needs attention
    func number(_ used: Double) -> NSColor { Format.severity(used) == .ok ? text : severity(used) }
}
