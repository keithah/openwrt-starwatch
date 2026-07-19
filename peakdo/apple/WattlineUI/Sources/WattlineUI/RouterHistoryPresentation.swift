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

public enum RouterHistoryPowerSeries: String, Equatable, Hashable, Sendable {
    case aggregate
    case dc
    case typeC

    public var label: String {
        switch self {
        case .aggregate: "Total"
        case .dc: "DC"
        case .typeC: "Type-C"
        }
    }
}

public struct RouterHistoryPowerSeriesPoint: Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let at: Date
    public let series: RouterHistoryPowerSeries
    public let watts: Double?
    /// Equal values form one continuous line. A nil sample has no segment and
    /// increments the next observed segment, so charts render a real gap.
    public let segment: Int?

    public init(
        id: Int,
        at: Date,
        series: RouterHistoryPowerSeries,
        watts: Double?,
        segment: Int?
    ) {
        self.id = id
        self.at = at
        self.series = series
        self.watts = watts
        self.segment = segment
    }
}

public struct RouterHistoryPresentation: Equatable, Sendable {
    public let points: [RouterHistoryPoint]
    public let powerPoints: [RouterHistoryPowerPoint]
    public let powerSeriesPoints: [RouterHistoryPowerSeriesPoint]
    public let fetchedAt: Date?

    public var isEmpty: Bool { points.isEmpty }

    public init(points: [RouterHistoryPoint], fetchedAt: Date?) {
        let sorted = points.sorted { $0.at < $1.at }
        self.points = sorted
        let aggregateWatts = sorted.map { point in
            let watts: Double? = switch (point.dcWatts, point.typeCWatts) {
            case (nil, nil): nil
            case let (dc, typeC): (dc ?? 0) + (typeC ?? 0)
            }
            return watts
        }
        powerPoints = zip(sorted, aggregateWatts).map {
            RouterHistoryPowerPoint(at: $0.0.at, watts: $0.1)
        }

        let dcWatts = sorted.map(\.dcWatts)
        let typeCWatts = sorted.map(\.typeCWatts)
        let aggregateSegments = Self.segments(for: aggregateWatts)
        let dcSegments = Self.segments(for: dcWatts)
        let typeCSegments = Self.segments(for: typeCWatts)
        var seriesPoints: [RouterHistoryPowerSeriesPoint] = []
        seriesPoints.reserveCapacity(sorted.count * 3)
        for index in sorted.indices {
            let values: [(
                RouterHistoryPowerSeries,
                Double?,
                Int?
            )] = [
                (.aggregate, aggregateWatts[index], aggregateSegments[index]),
                (.dc, dcWatts[index], dcSegments[index]),
                (.typeC, typeCWatts[index], typeCSegments[index]),
            ]
            for (series, watts, segment) in values {
                seriesPoints.append(RouterHistoryPowerSeriesPoint(
                    id: seriesPoints.count,
                    at: sorted[index].at,
                    series: series,
                    watts: watts,
                    segment: segment
                ))
            }
        }
        powerSeriesPoints = seriesPoints
        self.fetchedAt = fetchedAt
    }

    private static func segments(for values: [Double?]) -> [Int?] {
        var currentSegment = 0
        var hasObservedValue = false
        var gapAfterObservedValue = false
        return values.map { value in
            guard value != nil else {
                if hasObservedValue { gapAfterObservedValue = true }
                return nil
            }
            if gapAfterObservedValue {
                currentSegment += 1
                gapAfterObservedValue = false
            }
            hasObservedValue = true
            return currentSegment
        }
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
