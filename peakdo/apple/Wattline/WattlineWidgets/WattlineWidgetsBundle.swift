import SwiftUI
import WidgetKit

struct WattlineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Wattline", provider: WattlineWidgetProvider()) { entry in
            WattlineWidgetView(entry: entry)
        }
        .configurationDisplayName("Wattline")
        .description("Power station status")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct WattlineWidgetsBundle: WidgetBundle {
    var body: some Widget {
        WattlineWidget()
        #if os(iOS)
        WattlineLiveActivity()
        #endif
    }
}
