import Observation

@MainActor
@Observable
final class MacRouterEnrollmentLifecycle {
    private let route: RouterEnrollmentRoute
    private var generation: UInt64 = 0
    private var operationTask: Task<Void, Never>?
    private var hasActiveOperation = false

    private(set) var isSubmitting = false

    init(route: RouterEnrollmentRoute) {
        self.route = route
    }

    @discardableResult
    func beginSubmission() -> UInt64 {
        let generation = beginOperation()
        isSubmitting = true
        return generation
    }

    @discardableResult
    func beginSourceOperation() -> UInt64 {
        beginOperation()
    }

    func own(_ task: Task<Void, Never>, generation candidate: UInt64) {
        guard isCurrent(candidate) else {
            task.cancel()
            return
        }
        operationTask = task
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        hasActiveOperation && generation == candidate
    }

    @discardableResult
    func finish(generation candidate: UInt64) -> Bool {
        guard isCurrent(candidate) else { return false }
        operationTask = nil
        hasActiveOperation = false
        isSubmitting = false
        return true
    }

    func invalidatePreservingRoute() {
        invalidateOperation()
    }

    func invalidateAndClearRoute() {
        invalidateOperation()
        route.clear()
    }

    private func invalidateOperation() {
        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        hasActiveOperation = false
        isSubmitting = false
    }

    private func beginOperation() -> UInt64 {
        invalidateOperation()
        hasActiveOperation = true
        return generation
    }
}
