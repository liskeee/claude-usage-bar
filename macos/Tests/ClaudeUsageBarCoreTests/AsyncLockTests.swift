import Testing
@testable import ClaudeUsageBarCore

@MainActor struct AsyncLockTests {
    @MainActor final class Order { var values: [Int] = [] }

    @Test func waitersRunOneAtATime_inOrder() async {
        let lock = AsyncLock()
        let order = Order()
        await lock.lock()

        let first = Task { await lock.lock(); order.values.append(1); lock.unlock() }
        let second = Task { await lock.lock(); order.values.append(2); lock.unlock() }
        for _ in 0..<10 { await Task.yield() }
        #expect(order.values.isEmpty)

        lock.unlock()
        await first.value
        await second.value
        #expect(order.values == [1, 2])
        #expect(!lock.isLocked)
    }
}
