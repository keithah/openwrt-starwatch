import Foundation

public struct RouterHistoryPoint: Equatable, Sendable {
    public let at: Date
    public let level: Int
    public let dcWatts: Double?
    public let typeCWatts: Double?

    public init(at: Date, level: Int, dcWatts: Double?, typeCWatts: Double?) {
        self.at = at
        self.level = level
        self.dcWatts = dcWatts
        self.typeCWatts = typeCWatts
    }
}

public struct RouterHistoryPowerPoint: Equatable, Sendable {
    public let at: Date
    public let watts: Double?

    public init(at: Date, watts: Double?) {
        self.at = at
        self.watts = watts
    }
}

public struct RouterHistoryPresentation: Equatable, Sendable {
    public let points: [RouterHistoryPoint]
    public let powerPoints: [RouterHistoryPowerPoint]
    public let fetchedAt: Date?

    public var isEmpty: Bool { points.isEmpty }

    public init(points: [RouterHistoryPoint], fetchedAt: Date?) {
        let sorted = points.sorted { $0.at < $1.at }
        self.points = sorted
        powerPoints = sorted.map { point in
            let watts: Double? = switch (point.dcWatts, point.typeCWatts) {
            case (nil, nil): nil
            case let (dc, typeC): (dc ?? 0) + (typeC ?? 0)
            }
            return RouterHistoryPowerPoint(at: point.at, watts: watts)
        }
        self.fetchedAt = fetchedAt
    }
}
