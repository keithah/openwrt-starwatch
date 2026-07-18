import Foundation

enum AsyncTestWaitError: Error { case timedOut }

func waitUntil(
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw AsyncTestWaitError.timedOut }
        try await clock.sleep(for: .milliseconds(10))
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor AsyncCallBarrier {
    private var shouldHoldNext = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var completedHoldCount = 0

    var isBlocked: Bool { blocked }

    func holdNext() {
        shouldHoldNext = true
    }

    func waitIfHeld() async {
        guard shouldHoldNext else { return }
        shouldHoldNext = false
        blocked = true
        await withCheckedContinuation { continuation = $0 }
        completedHoldCount += 1
    }

    func release() {
        blocked = false
        continuation?.resume()
        continuation = nil
    }
}
