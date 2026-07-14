import Foundation
import SwiftUI
import WattlineCore
import XCTest
@testable import WattlineUI

@MainActor
private final class CallbackProbe {
    var toggleValue = false
    var selectionCount = 0

    func toggle(_ value: Bool) {
        toggleValue = value
    }

    func select() {
        selectionCount += 1
    }
}

final class ComponentAPITests: XCTestCase {
    @MainActor
    func testRepresentativeStaleAndPendingComponentAPIsCompile() throws {
        let battery = try BatteryStatus(frame: Data(repeating: 0, count: 16))
        let dc = try DCPortStatus(frame: Data(repeating: 0, count: 9))
        let typeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 13))
        let probe = CallbackProbe()

        _ = BatteryHero(status: battery, style: .gauge, compact: false, freshness: .stale)
        _ = DCPortHero(status: dc, compact: true, freshness: .stale)
        _ = PortCard(
            typeCStatus: typeC,
            compact: false,
            canToggle: true,
            isPending: true,
            freshness: .stale,
            onToggle: probe.toggle,
            onSelect: probe.select
        )
    }
}
