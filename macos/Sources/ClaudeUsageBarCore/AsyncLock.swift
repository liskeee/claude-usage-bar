/// A lock for async code on the main actor; waiters get it in order. Shared by the token renewer and the account
/// switcher, so a `claude -p` refresh never writes the old account's tokens over a switch.
@MainActor public final class AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isLocked: Bool { locked }

    public func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock straight to the next waiter, if any.
    public func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
