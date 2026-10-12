import Foundation

/// The words of the popover and the menu bar readout; the drawing lives in the app target.
public enum DisplayText {
    public static func footer(_ state: UsageState, now: Date, _ texts: Texts) -> String {
        switch (state.status, state.lastSuccess) {
        case (.ok, let last?): Texts.fill(texts.popup.updated, ("ago", Format.ago(now.timeIntervalSince(last), texts)))
        case (.error, let last?): Texts.fill(texts.popup.refreshFailed, ("ago", Format.ago(now.timeIntervalSince(last), texts)))
        case (.error, nil): texts.popup.loadFailed
        case (.needsLogin, _): texts.popup.signIn
        default: texts.popup.loading
        }
    }

    public static func resetLine(_ reset: Date, now: Date, _ texts: Texts, calendar: Calendar = .current) -> String {
        Texts.fill(texts.popup.resetLine,
            ("countdown", Format.countdownLong(reset.timeIntervalSince(now), texts)),
            ("moment", Format.resetMoment(reset, now: now, texts, calendar: calendar)))
    }

    /// Body text when there is no snapshot to show yet.
    public static func empty(_ state: UsageState, _ texts: Texts) -> String {
        switch state.status {
        case .needsLogin: texts.popup.emptyNeedsLogin
        case .error: texts.popup.emptyError
        default: texts.popup.emptyLoading
        }
    }

    /// "Claude Max 20x", or "Claude" before the plan is known.
    public static func heading(_ state: UsageState) -> String {
        state.planName.isEmpty ? "Claude" : "Claude \(state.planName)"
    }

    /// Data older than 15 minutes, or none yet, is drawn grey.
    public static func isStale(_ state: UsageState, now: Date) -> Bool {
        guard let last = state.lastSuccess else { return true }
        return now.timeIntervalSince(last) > UsageService.staleAfter
    }

    /// The VoiceOver label of the menu bar item.
    public static func accessibility(_ state: UsageState, now: Date, _ texts: Texts, calendar: Calendar = .current) -> String {
        if state.status == .needsLogin { return texts.bar.signIn }
        let limits = [state.snapshot?.session, state.snapshot?.weekly].compactMap { $0 }
        if limits.isEmpty { return "Claude: \(texts.popup.loading)" }
        return limits.map { limit in
            var part = "\(Format.limitLabel(limit, texts)) \(Format.percent(limit.usedPercent))"
            if let reset = limit.resetsAt { part += ", " + resetLine(reset, now: now, texts, calendar: calendar) }
            return part
        }.joined(separator: "; ")
    }
}
