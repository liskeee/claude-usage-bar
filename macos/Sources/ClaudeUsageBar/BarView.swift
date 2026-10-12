import AppKit
import ClaudeUsageBarCore

/// The two-row menu bar readout: "✻ 5h │ ▰▱ 38% │ 3h 49m" over "W │ ▰▱ 24% │ 6d 17h", with thin vertical lines
/// between the labels, the bars and numbers, and the countdowns.
@MainActor final class BarView: NSView {
    static let label = NSFont.systemFont(ofSize: 9)
    static let number = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    static let countdown = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    static let padding: CGFloat = 2, gap: CGFloat = 4, sparkRadius: CGFloat = 6.5
    static let barWidth: CGFloat = 22, barHeight: CGFloat = 3, lineGap: CGFloat = 3.5

    /// Where each column starts; sized for the widest text it can show, so nothing moves when the numbers change.
    struct Layout {
        var sparkX, labelX, firstLine, barX, numberRight, secondLine, countdownX, width: CGFloat
    }

    var state = UsageState.initial {
        didSet { tick() }
    }
    let texts: Texts
    let layout: Layout

    init(texts: Texts) {
        self.texts = texts
        layout = Self.layout(texts)
        super.init(frame: NSRect(x: 0, y: 0, width: layout.width, height: NSStatusBar.system.thickness))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func layout(_ texts: Texts) -> Layout {
        let labels = max(width(texts.bar.session, label), width(texts.bar.week, label))
        let countdowns = [86_399.0, 6 * 86_400 + 23 * 3_600].map { width(Format.countdownShort($0, texts), countdown) }.max() ?? 0
        let sparkX = padding + sparkRadius
        let labelX = sparkX + sparkRadius + 5
        let firstLine = labelX + labels + gap
        let barX = firstLine + 1 + gap
        let numberRight = barX + barWidth + gap + width("100%", number)
        let secondLine = numberRight + gap
        let countdownX = secondLine + 1 + gap
        return Layout(sparkX: sparkX, labelX: labelX, firstLine: firstLine, barX: barX, numberRight: numberRight,
                      secondLine: secondLine, countdownX: countdownX, width: countdownX + countdowns + padding)
    }

    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

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
        Spark.draw(center: CGPoint(x: layout.sparkX, y: bounds.midY), radius: Self.sparkRadius, color: palette.clay, flipped: true)
        if state.status == .needsLogin {
            let font = NSFont.systemFont(ofSize: 11)
            text(texts.bar.signIn, font: font, color: palette.muted, x: layout.labelX, baseline: bounds.midY + font.capHeight / 2)
            return
        }
        let now = Date()
        let stale = DisplayText.isStale(state, now: now)
        // the two rows' cap heights centred together in the bar
        let first = bounds.midY - Self.lineGap / 2
        let second = first + Self.number.capHeight + Self.lineGap
        row(texts.bar.session, state.snapshot?.session, baseline: first, palette: palette, stale: stale, now: now)
        row(texts.bar.week, state.snapshot?.weekly, baseline: second, palette: palette, stale: stale, now: now)
        palette.track.setFill()
        for x in [layout.firstLine, layout.secondLine] {
            NSRect(x: x, y: first - Self.number.capHeight - 1, width: 1, height: second - first + Self.number.capHeight + 2).fill()
        }
    }

    private func row(_ name: String, _ limit: LimitInfo?, baseline: CGFloat, palette: Palette, stale: Bool, now: Date) {
        text(name, font: Self.label, color: palette.muted, x: layout.labelX, baseline: baseline)
        let barY = baseline - Self.number.capHeight / 2 - Self.barHeight / 2 // on the middle of the digits
        pill(palette.track, x: layout.barX, y: barY, width: Self.barWidth)
        guard let limit else {
            text("…", font: Self.number, color: palette.muted, right: layout.numberRight, baseline: baseline)
            return
        }
        let used = min(max(limit.usedPercent, 0), 100)
        pill(stale ? palette.muted : palette.severity(limit.usedPercent), x: layout.barX, y: barY,
             width: max(Self.barHeight, Self.barWidth * used / 100))
        text(Format.percent(limit.usedPercent), font: Self.number, color: stale ? palette.muted : palette.number(limit.usedPercent),
             right: layout.numberRight, baseline: baseline)
        if let reset = limit.resetsAt {
            text(Format.countdownShort(reset.timeIntervalSince(now), texts), font: Self.countdown, color: palette.muted,
                 x: layout.countdownX, baseline: baseline)
        }
    }

    private func text(_ string: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
        (string as NSString).draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: color])
    }

    private func text(_ string: String, font: NSFont, color: NSColor, right: CGFloat, baseline: CGFloat) {
        text(string, font: font, color: color, x: right - Self.width(string, font), baseline: baseline)
    }

    private func pill(_ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: Self.barHeight),
                     xRadius: Self.barHeight / 2, yRadius: Self.barHeight / 2).fill()
    }
}
