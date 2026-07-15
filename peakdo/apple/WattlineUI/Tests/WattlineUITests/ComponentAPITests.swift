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
    func testStatTileDimsTelemetryWhenStale() {
        let live = StatTile(label: "Voltage", value: "20.0", unit: "V", freshness: .live)
        let stale = StatTile(label: "Voltage", value: "20.0", unit: "V", freshness: .stale)

        XCTAssertEqual(live.telemetryOpacity, 1)
        XCTAssertEqual(stale.telemetryOpacity, 0.58)
    }

    @MainActor
    func testRepresentativeStaleAndPendingComponentAPIsCompile() throws {
        let battery = try BatteryStatus(frame: Data(repeating: 0, count: 16))
        let dc = try DCPortStatus(frame: Data(repeating: 0, count: 9))
        let typeC = try TypeCPortStatus(frame: Data(repeating: 0, count: 13))
        let probe = CallbackProbe()

        let batteryHero = BatteryHero(status: battery, style: .gauge, compact: false, freshness: .stale)
        let dcHero = DCPortHero(status: dc, compact: true, freshness: .stale)
        let card = PortCard(
            typeCStatus: typeC,
            compact: false,
            canToggle: true,
            isPending: true,
            freshness: .stale,
            onToggle: probe.toggle,
            onSelect: probe.select
        )

        XCTAssertEqual(batteryHero.status, battery)
        XCTAssertEqual(batteryHero.freshness, .stale)
        XCTAssertEqual(dcHero.status, dc)
        XCTAssertTrue(card.isPending)
        XCTAssertEqual(card.freshness, .stale)
        card.onToggle?(true)
        card.onSelect?()
        XCTAssertTrue(probe.toggleValue)
        XCTAssertEqual(probe.selectionCount, 1)
    }

    @MainActor
    func testThemeMapsChargingAndDischargingSemantics() {
        XCTAssertEqual(WattlineTheme.color(for: .charging), WattlineTheme.charging)
        XCTAssertEqual(WattlineTheme.color(for: .discharging), WattlineTheme.discharging)
        XCTAssertEqual(WattlineTheme.color(for: .idle), WattlineTheme.idle)
    }
}
