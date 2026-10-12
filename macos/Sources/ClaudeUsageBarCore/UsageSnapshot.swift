import Foundation

public enum LimitKind: Sendable, Equatable { case session, weekly, weeklyScoped }

/// One usage limit exactly as claude.ai → Settings → Usage shows it (percent = used).
/// `model` is set for per-model weekly limits (e.g. "Fable"); the label is localized by the UI.
public struct LimitInfo: Sendable, Equatable {
    public var kind: LimitKind
    public var usedPercent: Double
    public var resetsAt: Date?
    public var model: String?

    public init(_ kind: LimitKind, _ usedPercent: Double, resetsAt: Date?, model: String? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.model = model
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var limits: [LimitInfo]
    public var fetchedAt: Date

    public init(limits: [LimitInfo], fetchedAt: Date) {
        self.limits = limits
        self.fetchedAt = fetchedAt
    }

    public var session: LimitInfo? { limits.first { $0.kind == .session } }
    public var weekly: LimitInfo? { limits.first { $0.kind == .weekly } }
}
