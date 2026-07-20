import Charts
import SwiftUI
import WattlineNetwork
import WattlineUI

struct RouterHistoryView: View {
    let model: RouterAdministrationModel

    private var history: RouterHistoryPresentation {
        RouterHistoryPresentation(
            points: model.history.map {
                RouterHistoryPoint(
                    at: $0.at, level: $0.level,
                    dcWatts: $0.dcWatts, typeCWatts: $0.typeCWatts
                )
            },
            fetchedAt: model.historyFetchedAt
        )
    }

    private var presentation: RouterHistoryScreenPresentation {
        RouterHistoryScreenPresentation(
            history: history,
            loadState: loadState
        )
    }

    private var loadState: RouterHistoryLoadState {
        switch model.historyLoadState {
        case .neverLoaded: .neverLoaded
        case .initialLoading: .initialLoading
        case .loaded: .loaded
        case .failed:
            .failed(message: model.historyError ?? "Could not load router history.")
        case .refreshing: .refreshing
        }
    }

    var body: some View {
        Group {
            if presentation.showsInitialProgress || presentation.showsEmptyRefreshProgress {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity)
            } else if let message = presentation.emptyFailureMessage {
                ContentUnavailableView {
                    Label("History unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
                .accessibilityIdentifier("state.unavailable")
                .accessibilityLabel("Router history unavailable. \(message)")
            } else if presentation.showsSuccessfulEmpty {
                ContentUnavailableView {
                    Label("No history yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("The router records about one sample per minute while it can reach the Link-Power.")
                }
            } else if presentation.showsNeverLoaded {
                ContentUnavailableView {
                    Label("History not loaded", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Open this router to load its recorded history.")
                }
            } else if presentation.showsCharts {
                VStack(alignment: .leading, spacing: 16) {
                    if presentation.showsRefreshProgress {
                        ProgressView("Refreshing history…")
                    }

                    Chart(presentation.history.points, id: \.at) { point in
                        LineMark(
                            x: .value("Time", point.at),
                            y: .value("Battery %", point.level)
                        )
                    }
                    .chartYScale(domain: 0...100)
                    .frame(minHeight: 160)
                    .accessibilityLabel("Battery level history chart")

                    Chart {
                        ForEach(presentation.history.powerSeriesPoints) { point in
                            if let watts = point.watts,
                               let segment = point.segment {
                                LineMark(
                                    x: .value("Time", point.at),
                                    y: .value("Watts", watts),
                                    series: .value(
                                        "Line segment",
                                        "\(point.series.rawValue)-\(segment)"
                                    )
                                )
                                .foregroundStyle(by: .value(
                                    "Power series",
                                    point.series.label
                                ))
                                .symbol(by: .value(
                                    "Power series",
                                    point.series.label
                                ))
                                .lineStyle(StrokeStyle(
                                    lineWidth: point.series == .aggregate ? 3 : 1.5,
                                    dash: point.series == .typeC ? [5, 3] : []
                                ))
                            }
                        }
                    }
                    .frame(minHeight: 120)
                    .accessibilityLabel("DC and USB-C power history chart")

                    if let fetchedAt = presentation.history.fetchedAt {
                        Text("Fetched \(fetchedAt.formatted(date: .omitted, time: .standard))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if let message = presentation.failureMessage {
                        Text(message)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("state.stale")
                            .accessibilityLabel("History may be stale. \(message)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("history.chart")
            }
        }
    }
}
