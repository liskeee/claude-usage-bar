import Foundation

public enum Severity: Sendable { case ok, warn, critical }

/// Text and number formatting shared by the menu bar readout and the popover; wording comes from Texts.
public enum Format {
    // green < 50, amber 50–80, red > 80
    public static func severity(_ used: Double) -> Severity {
        used < 50 ? .ok : used <= 80 ? .warn : .critical
    }

    public static func percent(_ used: Double) -> String {
        "\(Int(used.rounded(.toNearestOrAwayFromZero)))%"
    }

    /// Menu bar countdown, e.g. "52m", "3h 49m", "6d 17h".
    public static func countdownShort(_ t: TimeInterval, _ texts: Texts) -> String {
        let time = texts.time
        if t < 60 { return time.lessThanMinute }
        if t < 3600 { return Texts.fill(time.minutes, ("m", "\(Int(t / 60))")) }
        if t < 86400 {
            return Texts.fill(time.hoursMinutes, ("h", "\(Int(t / 3600))"), ("m", "\(Int(t.truncatingRemainder(dividingBy: 3600) / 60))"))
        }
        return Texts.fill(time.daysHours, ("d", "\(Int(t / 86400))"), ("h", "\(Int(t.truncatingRemainder(dividingBy: 86400) / 3600))"))
    }

    /// Popover countdown, e.g. "in 3h 49m".
    public static func countdownLong(_ t: TimeInterval, _ texts: Texts) -> String {
        t < 60 ? texts.time.inAMoment : Texts.fill(texts.time.in, ("duration", countdownShort(t, texts)))
    }

    /// Age of the data, e.g. "just now", "2m ago".
    public static func ago(_ t: TimeInterval, _ texts: Texts) -> String {
        t < 60 ? texts.time.justNow : Texts.fill(texts.time.ago, ("duration", countdownShort(t, texts)))
    }

    /// e.g. "today 18:00", "tomorrow 08:00", "Thu 8 Oct, 08:00", in `calendar`'s time zone.
    public static func resetMoment(_ reset: Date, now: Date, _ texts: Texts, calendar: Calendar = .current) -> String {
        // the API reports e.g. 17:59:59.9 for an 18:00 reset
        let rounded = Date(timeIntervalSinceReferenceDate: (reset.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let parts = calendar.dateComponents([.hour, .minute, .day, .month, .weekday], from: rounded)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let time = texts.time
        if calendar.isDate(rounded, inSameDayAs: now) { return Texts.fill(time.today, ("time", clock)) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(rounded, inSameDayAs: tomorrow) {
            return Texts.fill(time.tomorrow, ("time", clock))
        }
        let weekday = parts.weekday ?? 1, month = parts.month ?? 1
        return Texts.fill(time.otherDay,
            ("weekday", time.weekdays[weekday - 1]), ("day", "\(parts.day ?? 1)"),
            ("month", time.months[month - 1]), ("monthNumber", "\(month)"), ("time", clock))
    }

    public static func limitLabel(_ limit: LimitInfo, _ texts: Texts) -> String {
        switch limit.kind {
        case .session: texts.limits.session
        case .weekly: texts.limits.weekly
        case .weeklyScoped: Texts.fill(texts.limits.scoped, ("model", limit.model ?? texts.limits.unknownModel))
        }
    }

    /// "default_claude_max_20x" → "Max 20x"; otherwise the capitalised subscription type.
    public static func planName(subscriptionType: String?, rateLimitTier: String?) -> String {
        if let tier = rateLimitTier, let match = tier.firstMatch(of: #/max_(\d+)x/#) { return "Max \(match.1)x" }
        guard let type = subscriptionType, !type.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return type.prefix(1).uppercased() + type.dropFirst()
    }

    /// "lukasz@gmail.com" → "l***@gmail.com": enough to tell accounts apart in the log.
    public static func maskEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex, let first = email.first else { return "***" }
        return "\(first)***\(email[at...])"
    }
}
