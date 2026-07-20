#if os(iOS)
import ActivityKit
import Foundation

public struct WattlineActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public let level: Int
        public let status: Int8
        public let runtimeSeconds: Int?
        public let aggregateOutputWatts: Double
        public let observedAt: Date
        public let isConnected: Bool
        public init(level: Int, status: Int8, runtimeSeconds: Int?, aggregateOutputWatts: Double, observedAt: Date, isConnected: Bool) {
            self.level = level; self.status = status; self.runtimeSeconds = runtimeSeconds; self.aggregateOutputWatts = aggregateOutputWatts; self.observedAt = observedAt; self.isConnected = isConnected
        }
    }
    public init() {}
}
#endif
