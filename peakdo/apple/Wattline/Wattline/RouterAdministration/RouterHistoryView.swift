import Charts
import SwiftUI
import WattlineNetwork
import WattlineUI

struct RouterHistoryView: View {
    let model: RouterAdministrationModel

    private var presentation: RouterHistoryPresentation {
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

    var body: some View {
        Group {
            if presentation.isEmpty {
                ContentUnavailableView {
                    Label("No history yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("The router records about one sample per minute while it can reach the Link-Power.")
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Chart(presentation.points, id: \.at) { point in
                        LineMark(
                            x: .value("Time", point.at),
                            y: .value("Battery %", point.level)
                        )
                    }
                    .chartYScale(domain: 0...100)
                    .frame(minHeight: 160)

                    Chart(presentation.powerPoints.filter { $0.watts != nil }, id: \.at) { point in
                        LineMark(
                            x: .value("Time", point.at),
                            y: .value("Watts", point.watts ?? 0)
                        )
                    }
                    .frame(minHeight: 120)

                    if let fetchedAt = presentation.fetchedAt {
                        Text("Fetched \(fetchedAt.formatted(date: .omitted, time: .standard))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .task { await model.reloadHistory() }
    }
}
