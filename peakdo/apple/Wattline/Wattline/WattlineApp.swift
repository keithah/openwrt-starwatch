import SwiftUI
import WattlineUI

@main
struct WattlineApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            AppPersistence().resetOnboarding()
        }
        if ProcessInfo.processInfo.arguments.contains("-resetHeroStyle") {
            UserDefaults.standard.set("segmented", forKey: "batteryHeroStyle")
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(WattlineTheme.accent)
        }
    }
}
