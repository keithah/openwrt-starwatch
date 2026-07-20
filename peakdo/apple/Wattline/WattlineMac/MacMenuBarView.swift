import AppKit
import SwiftUI
import WattlineUI

struct MacMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    let model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Wattline", systemImage: "bolt.fill")
                    .font(.headline)
                Spacer()
                if model.isDemo { DemoBadge() }
            }

            Text(model.isDemo ? "Demo device" : "Looking for devices…")
                .foregroundStyle(.secondary)

            if model.isDemo {
                Button("Connect a real device") {
                    model.connectRealDevice()
                }
            }

            Divider()

            Button("Open Wattline") {
                NSApplication.shared.activate()
                openWindow(id: "main")
            }
            .keyboardShortcut("o")

            Button("Quit Wattline") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 280)
        .task { model.start() }
    }
}
