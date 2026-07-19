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

public enum RouterHistoryLoadState: Equatable, Sendable {
    case neverLoaded
    case initialLoading
    case loaded
    case failed(message: String)
    case refreshing
}

public struct RouterHistoryScreenPresentation: Equatable, Sendable {
    public let history: RouterHistoryPresentation
    public let loadState: RouterHistoryLoadState

    public init(
        history: RouterHistoryPresentation,
        loadState: RouterHistoryLoadState
    ) {
        self.history = history
        self.loadState = loadState
    }

    public var showsCharts: Bool { !history.isEmpty }

    public var showsNeverLoaded: Bool {
        history.isEmpty && loadState == .neverLoaded
    }

    public var showsInitialProgress: Bool {
        history.isEmpty && loadState == .initialLoading
    }

    public var showsSuccessfulEmpty: Bool {
        history.isEmpty && loadState == .loaded
    }

    public var showsRefreshProgress: Bool {
        !history.isEmpty && loadState == .refreshing
    }

    public var showsEmptyRefreshProgress: Bool {
        history.isEmpty && loadState == .refreshing
    }

    public var failureMessage: String? {
        guard case let .failed(message) = loadState else { return nil }
        return message
    }

    public var emptyFailureMessage: String? {
        history.isEmpty ? failureMessage : nil
    }
}
