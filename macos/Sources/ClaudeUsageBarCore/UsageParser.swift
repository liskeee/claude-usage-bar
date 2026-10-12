import Foundation

/// Maps the /api/oauth/usage response to a snapshot; prefers `limits[]`, falls back to `five_hour` / `seven_day`.
public enum UsageParser {
    public static func parse(_ json: String, fetchedAt: Date) throws -> UsageSnapshot {
        let root = try JSONValue.parse(Data(json.utf8))
        guard root.object != nil else { throw JSONValue.Unsupported() }
        var limits: [LimitInfo] = []
        if case .array(let items)? = root["limits"] {
            limits = items.compactMap(fromLimitsItem)
        }
        if limits.isEmpty {
            addLegacy(root["five_hour"], .session, to: &limits)
            addLegacy(root["seven_day"], .weekly, to: &limits)
        }
        return UsageSnapshot(limits: limits, fetchedAt: fetchedAt)
    }

    static func fromLimitsItem(_ item: JSONValue) -> LimitInfo? {
        guard let percent = item["percent"]?.number else { return nil }
        let resets = item["resets_at"]?.string.flatMap(date)
        switch item["kind"]?.string {
        case "session": return LimitInfo(.session, percent, resetsAt: resets)
        case "weekly_all": return LimitInfo(.weekly, percent, resetsAt: resets)
        case "weekly_scoped":
            return LimitInfo(.weeklyScoped, percent, resetsAt: resets, model: item["scope"]?["model"]?["display_name"]?.string)
        default: return nil
        }
    }

    static func addLegacy(_ value: JSONValue?, _ kind: LimitKind, to limits: inout [LimitInfo]) {
        guard let value, let used = value["utilization"]?.number else { return }
        limits.append(LimitInfo(kind, used, resetsAt: value["resets_at"]?.string.flatMap(date)))
    }

    /// "2026-10-01T18:00:00.345899+02:00": whole seconds go through ISO8601DateFormatter and the fraction
    /// (any number of digits) is added on top.
    public static func date(_ text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let dot = whole.firstIndex(of: "."),
           let end = whole[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            fraction = Double("0" + whole[dot..<end]) ?? 0
            whole.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole)?.addingTimeInterval(fraction)
    }
}
