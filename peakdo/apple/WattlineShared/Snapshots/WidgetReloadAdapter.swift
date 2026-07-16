import Foundation
import WidgetKit
import WattlineCore

@MainActor
final class WidgetReloadAdapter {
    private let reload: @MainActor () -> Void
    init(reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: "Wattline") }) { self.reload = reload }
    func apply(_ decision: SnapshotFanOutDecision) { if decision.reloadWidgets { reload() } }
}
