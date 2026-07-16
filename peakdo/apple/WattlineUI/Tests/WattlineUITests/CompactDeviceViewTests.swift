import Foundation
import SwiftUI
import WattlineCore
import XCTest
@testable import WattlineUI

@MainActor
private final class CompactToggleProbe {
    var callCount = 0

    func toggle() {
        callCount += 1
    }
}

final class CompactDeviceViewTests: XCTestCase {
    private func snapshot(battery: SharedBatterySnapshot?) -> SharedDeviceSnapshot {
        SharedDeviceSnapshot(
            peripheralID: UUID(),
            featuresRawValue: 0,
            battery: battery,
            dc: nil,
            typeC: nil,
            connection: .live,
            observedAt: Date()
        )
    }

    private func battery(status: PowerFlow = .charging, level: UInt8 = 62, power: Double = 24, isFull: Bool = false) -> SharedBatterySnapshot {
        SharedBatterySnapshot(
            enabled: true,
            status: status,
            isFull: isFull,
            maxCapacity: 100,
            capacity: 62,
            level: level,
            voltage: 12,
            current: 2,
            power: power,
            remainingMinutes: 90
        )
    }

    // MARK: - CompactBatteryHero

    @MainActor
    func testCompactBatteryHeroDimsTelemetryWhenStale() {
        let snap = snapshot(battery: battery())
        let live = CompactBatteryHero(snapshot: snap, freshness: .live)
        let stale = CompactBatteryHero(snapshot: snap, freshness: .stale)

        XCTAssertEqual(live.telemetryOpacity, 1)
        XCTAssertEqual(stale.telemetryOpacity, 0.58)
    }

    @MainActor
    func testCompactBatteryHeroAbsentWhenBatteryCapabilityUnsupported() {
        let noBattery = CompactBatteryHero(snapshot: snapshot(battery: nil), freshness: .live)
        XCTAssertFalse(noBattery.isSupported)

        let withBattery = CompactBatteryHero(snapshot: snapshot(battery: battery()), freshness: .live)
        XCTAssertTrue(withBattery.isSupported)
    }

    // MARK: - CompactPortCard

    @MainActor
    func testCompactPortCardExposesPendingState() {
        let presentation = PortCardPresentation(dcStatus: try! DCPortStatus(frame: Data(repeating: 0, count: 9)))
        let pending = CompactPortCard(presentation: presentation, isPending: true, onToggle: nil)
        let idle = CompactPortCard(presentation: presentation, isPending: false, onToggle: nil)

        XCTAssertTrue(pending.isPending)
        XCTAssertFalse(idle.isPending)
    }

    @MainActor
    func testCompactPortCardOmitsToggleCapabilityWhenUnsupported() {
        let dc = try! DCPortStatus(frame: Data(repeating: 0, count: 9))
        let withoutControl = PortCardPresentation(dcStatus: dc, canToggle: false)
        let withControl = PortCardPresentation(dcStatus: dc, canToggle: true)

        XCTAssertFalse(withoutControl.canToggle)
        XCTAssertTrue(withControl.canToggle)

        let card = CompactPortCard(presentation: withoutControl, isPending: false, onToggle: nil)
        XCTAssertFalse(card.presentation.canToggle)
    }

    @MainActor
    func testCompactPortCardInvokesOnToggleCallback() {
        let presentation = PortCardPresentation(
            typeCStatus: try! TypeCPortStatus(frame: Data(repeating: 0, count: 13))
        )
        let probe = CompactToggleProbe()
        let card = CompactPortCard(presentation: presentation, isPending: false, onToggle: probe.toggle)

        card.onToggle?()

        XCTAssertEqual(probe.callCount, 1)
    }

    // MARK: - PortCardPresentation reuse (no forked detail logic)

    @MainActor
    func testPortCardPresentationDCDetailMatchesPortCardDetail() throws {
        let dc = try DCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0, 1]))

        XCTAssertEqual(
            PortCardPresentation(dcStatus: dc, showsBypass: true).detail,
            PortCard(dcStatus: dc, showsBypass: true).detail
        )
        XCTAssertEqual(
            PortCardPresentation(dcStatus: dc, showsBypass: false).detail,
            PortCard(dcStatus: dc, showsBypass: false).detail
        )
    }

    @MainActor
    func testPortCardPresentationTypeCDetailMatchesPortCardDetail() throws {
        let typeC = try TypeCPortStatus(frame: Data([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))

        XCTAssertEqual(
            PortCardPresentation(typeCStatus: typeC, showsDCInput: true).detail,
            PortCard(typeCStatus: typeC, showsDCInput: true).detail
        )
        XCTAssertEqual(
            PortCardPresentation(typeCStatus: typeC, showsDCInput: false).detail,
            PortCard(typeCStatus: typeC, showsDCInput: false).detail
        )
    }
}
