import Foundation

public enum ServiceStatus: Sendable, Equatable { case loading, ok, error, needsLogin }

/// Everything the UI draws; replaced as a whole on every refresh.
public struct UsageState: Sendable, Equatable {
    public var status: ServiceStatus
    public var snapshot: UsageSnapshot?
    public var planName: String
    public var lastSuccess: Date?
    public var lastError: String?

    public init(status: ServiceStatus, snapshot: UsageSnapshot?, planName: String, lastSuccess: Date?, lastError: String?) {
        self.status = status
        self.snapshot = snapshot
        self.planName = planName
        self.lastSuccess = lastSuccess
        self.lastError = lastError
    }

    public static let initial = UsageState(status: .loading, snapshot: nil, planName: "", lastSuccess: nil, lastError: nil)
}

/// Token → (renew) → fetch → state. Keeps the last good snapshot when a refresh fails.
@MainActor public final class UsageService {
    nonisolated public static let pollInterval: TimeInterval = 5 * 60
    nonisolated public static let staleAfter: TimeInterval = 15 * 60
    nonisolated static let expirySkew: TimeInterval = 60
    nonisolated static let afterReset: TimeInterval = 15
    nonisolated static let maxBackoff: TimeInterval = 30 * 60

    let credentials: any CredentialSource
    let api: any UsageAPI
    let renewer: any TokenRenewing
    let time: any TimeSource
    private let gate = AsyncLock()
    private var rateLimitStreak = 0 // consecutive HTTP 429 answers; the endpoint refills slowly once drained
    private var generation = 0 // bumped by reset(): a refresh that started earlier belongs to the previous account

    public private(set) var state = UsageState.initial
    public var onChange: ((UsageState) -> Void)?

    public init(credentials: any CredentialSource, api: any UsageAPI, renewer: any TokenRenewing, time: any TimeSource) {
        self.credentials = credentials
        self.api = api
        self.renewer = renewer
        self.time = time
    }

    public func refresh() async {
        await gate.lock()
        defer { gate.unlock() }
        let started = generation
        let next = await fetch()
        guard started == generation else {
            rateLimitStreak = 0 // whatever that refresh counted was about the account we left
            return
        }
        state = next
        let session = state.snapshot?.session.map { "\($0.usedPercent)" } ?? "-"
        let week = state.snapshot?.weekly.map { "\($0.usedPercent)" } ?? "-"
        Log.write("refresh: \(state.status) session=\(session) week=\(week) \(state.lastError ?? "")")
        onChange?(state)
    }

    /// After an account switch: back to loading with no data and no backoff, so the previous account's numbers
    /// never show under the new one.
    public func reset() {
        generation += 1
        rateLimitStreak = 0
        renewer.reset()
        state = .initial
        onChange?(state)
    }

    /// Next automatic refresh: the poll interval, or just after the session limit resets if that comes sooner;
    /// while rate limited, 10 → 20 → 30 min.
    public func nextDelay() -> TimeInterval {
        if rateLimitStreak > 0 {
            return min(Self.maxBackoff, Self.pollInterval * pow(2, Double(min(rateLimitStreak, 8))))
        }
        if let reset = state.snapshot?.session?.resetsAt {
            let untilReset = reset.timeIntervalSince(time.now())
            if untilReset > 0 && untilReset + Self.afterReset < Self.pollInterval { return untilReset + Self.afterReset }
        }
        return Self.pollInterval
    }

    private func fetch() async -> UsageState {
        var creds: Credentials?
        do {
            creds = try await credentials.read()
            if !isUsable(creds) {
                _ = await renewer.tryRenew()
                creds = try await credentials.read()
            }
        } catch {
            // e.g. a locked Keychain: transient, keep what is on screen
            return failed(error as? KeychainError == .locked ? "Keychain locked" : "Keychain read failed", plan: state.planName)
        }
        guard var current = creds, isUsable(current) else { return needsLogin(creds, "CLI login expired") }

        var result = await api.fetch(accessToken: current.accessToken)
        if result == .unauthorized {
            _ = await renewer.tryRenew()
            guard let renewed = try? await credentials.read(), isUsable(renewed) else { return needsLogin(current, "CLI login expired") }
            current = renewed
            result = await api.fetch(accessToken: current.accessToken)
            if result == .unauthorized { return needsLogin(current, result.error) }
        }

        let plan = Format.planName(subscriptionType: current.subscriptionType, rateLimitTier: current.rateLimitTier)
        switch result {
        case .ok(let json):
            guard let snapshot = try? UsageParser.parse(json, fetchedAt: time.now()) else {
                var next = state
                next.status = .error
                next.planName = plan
                next.lastError = "Unreadable API response"
                return next
            }
            rateLimitStreak = 0
            return UsageState(status: .ok, snapshot: snapshot, planName: plan, lastSuccess: snapshot.fetchedAt, lastError: nil)
        case .rateLimited:
            rateLimitStreak += 1
            return failed(result.error, plan: plan)
        default:
            return failed(result.error, plan: plan)
        }
    }

    /// A failed refresh only matters once the data already on screen gets old.
    private func failed(_ error: String?, plan: String) -> UsageState {
        let fresh = state.lastSuccess.map { time.now().timeIntervalSince($0) <= Self.staleAfter } ?? false
        var next = state
        next.status = fresh ? .ok : .error
        next.planName = plan
        next.lastError = error
        return next
    }

    private func needsLogin(_ creds: Credentials?, _ error: String?) -> UsageState {
        var next = state
        next.status = .needsLogin
        if let creds { next.planName = Format.planName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier) }
        next.lastError = error
        return next
    }

    private func isUsable(_ creds: Credentials?) -> Bool {
        guard let creds else { return false }
        return creds.expiresAt.addingTimeInterval(-Self.expirySkew) > time.now()
    }
}
