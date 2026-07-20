#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

struct WattlineLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WattlineActivityAttributes.self) { context in
            VStack(alignment: .leading) {
                Text("\(context.state.level)%").font(.system(size: 34, weight: .bold, design: .monospaced))
                Text(context.state.isConnected ? "\(Int(context.state.aggregateOutputWatts)) W" : "Stale")
                    .font(.system(.body, design: .monospaced)).foregroundStyle(color(status: context.state.status))
                if let runtime = context.state.runtimeSeconds { Text(runtimeLabel(runtime, status: context.state.status)).font(.system(.caption, design: .monospaced)) }
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland { DynamicIslandExpandedRegion(.center) { Text("\(context.state.level)%").font(.system(.title, design: .monospaced)).foregroundStyle(color(status: context.state.status)) } } compactLeading: { Text("⚡︎") } compactTrailing: { Text("\(context.state.level)%").font(.system(.caption, design: .monospaced)) } minimal: { Text("\(context.state.level)%").font(.system(.caption2, design: .monospaced)) }
        }
    }
    private func color(status: Int8) -> Color { status > 0 ? .green : status < 0 ? .orange : .secondary }
    private func runtimeLabel(_ seconds: Int, status: Int8) -> String {
        let direction = status < 0 ? "Left" : "To full"
        return "\(direction): \(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
#endif
