import SwiftUI

@main
struct WattlineApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            AppPersistence().resetOnboarding()
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
