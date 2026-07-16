import SwiftUI
import WidgetKit

struct WattlinePlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WattlinePlaceholder", provider: PlaceholderProvider()) { entry in
            Text(entry.title)
        }
        .configurationDisplayName("Wattline")
        .description("Power station status")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct PlaceholderEntry: TimelineEntry {
    let date: Date
    let title: String
}

private struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now, title: "Wattline") }
    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) { completion(PlaceholderEntry(date: .now, title: "Wattline")) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) { completion(Timeline(entries: [PlaceholderEntry(date: .now, title: "Wattline")], policy: .never)) }
}

@main
struct WattlineWidgetsBundle: WidgetBundle {
    var body: some Widget { WattlinePlaceholderWidget() }
}
