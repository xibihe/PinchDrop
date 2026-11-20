import Foundation

// Bound CPU/GPU overlap without accumulating an unbounded queue of old head poses.
final class RenderInFlightGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0

    func acquire(limit: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 0.02)
        while count >= max(1, limit) {
            if !condition.wait(until: deadline) { return false }
        }
        count += 1
        return true
    }

    func release() {
        condition.lock()
        precondition(count > 0)
        count -= 1
        condition.broadcast()
        condition.unlock()
    }

    var activeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return count
    }
}
