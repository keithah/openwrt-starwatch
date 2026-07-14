public actor SerializedTransactions {
    private var tail: Task<Void, Never>?

    public init() {}

    public func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let predecessor = tail
        let task = Task {
            await predecessor?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
