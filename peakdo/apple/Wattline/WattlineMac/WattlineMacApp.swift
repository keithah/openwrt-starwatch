import SwiftUI
import WattlineUI

@main
struct WattlineMacApp: App {
    @State private var model = MacAppModel.production()

    var body: some Scene {
        MenuBarExtra("Wattline", systemImage: "bolt.fill") {
            MacMenuBarView(model: model)
        }

        WindowGroup("Wattline", id: "main") {
            MacRootView(model: model)
                .tint(WattlineTheme.accent)
                .onOpenURL { model.acceptPairingURL($0) }
        }
        .defaultSize(width: 980, height: 680)
    }
}
