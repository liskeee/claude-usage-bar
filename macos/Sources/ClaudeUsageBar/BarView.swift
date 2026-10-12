import AppKit
import ClaudeUsageBarCore

/// The two-row menu bar readout: "✻ 5h ▰▱ 38% 3h 49m" over "W ▰▱ 24% 6d 17h" (the Windows BarRenderer layout).
@MainActor final class BarView: NSView {
    static let width: CGFloat = 126
    static let label = NSFont.systemFont(ofSize: 9.5)
    static let number = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    var state = UsageState.initial {
        didSet { tick() }
    }
    let texts: Texts

    init(texts: Texts) {
        self.texts = texts
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: NSStatusBar.system.thickness))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    // clicks go to the status bar button underneath
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    /// Redraws: countdowns move on, data turns grey when it gets old.
    func tick() {
        needsDisplay = true
        setAccessibilityLabel(DisplayText.accessibility(state, now: Date(), texts))
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current(effectiveAppearance)
        let middle = bounds.midY
        Spark.draw(center: CGPoint(x: 9, y: middle), radius: 6.5, color: palette.clay, flipped: true)
        if state.status == .needsLogin {
            text(texts.bar.signIn, font: .systemFont(ofSize: 12), color: palette.muted, x: 20, baseline: middle + 4)
            return
        }
        let now = Date()
        let stale = DisplayText.isStale(state, now: now)
        row(texts.bar.session, state.snapshot?.session, baseline: middle - 1.5, palette: palette, stale: stale, now: now)
        row(texts.bar.week, state.snapshot?.weekly, baseline: middle + 9, palette: palette, stale: stale, now: now)
    }

    private func row(_ name: String, _ limit: LimitInfo?, baseline: CGFloat, palette: Palette, stale: Bool, now: Date) {
        let x: CGFloat = 20
        text(name, font: Self.label, color: palette.muted, x: x, baseline: baseline)
        let barX = x + 12, barWidth: CGFloat = 24, barHeight: CGFloat = 3.5
        let barY = baseline - 3.5 - barHeight / 2
        let numberRight = barX + barWidth + 31 // room for "100%" after the bar
        pill(palette.track, x: barX, y: barY, width: barWidth, height: barHeight)
        guard let limit else {
            text("…", font: Self.number, color: palette.muted, right: numberRight, baseline: baseline)
            return
        }
        let used = min(max(limit.usedPercent, 0), 100)
        pill(stale ? palette.muted : palette.severity(limit.usedPercent), x: barX, y: barY,
             width: max(barHeight, barWidth * used / 100), height: barHeight)
        text(Format.percent(limit.usedPercent), font: Self.number, color: stale ? palette.muted : palette.number(limit.usedPercent),
             right: numberRight, baseline: baseline)
        if let reset = limit.resetsAt {
            text(Format.countdownShort(reset.timeIntervalSince(now), texts), font: Self.label, color: palette.muted, x: numberRight + 3, baseline: baseline)
        }
    }

    private func text(_ string: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
        (string as NSString).draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: color])
    }

    private func text(_ string: String, font: NSFont, color: NSColor, right: CGFloat, baseline: CGFloat) {
        let width = (string as NSString).size(withAttributes: [.font: font]).width
        text(string, font: font, color: color, x: right - width, baseline: baseline)
    }

    private func pill(_ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
    }
}
