import Foundation
import WattlineCore

public enum PreferredDeviceTransport: Equatable, Sendable {
    case bluetooth
    case router
}

public struct UnifiedDeviceRecord: Equatable, Sendable {
    public let bluetoothIdentity: DeviceIdentitySnapshot?
    public let routerIdentity: DeviceIdentitySnapshot?
    public let preferredTransport: PreferredDeviceTransport
    public let normalizedMAC: String?

    public var identity: DeviceIdentitySnapshot {
        bluetoothIdentity ?? routerIdentity!
    }
}

public enum DeviceIdentityDeduplicator {
    public static func merge(
        ble: DeviceIdentitySnapshot?,
        router: DeviceIdentitySnapshot?
    ) -> UnifiedDeviceRecord? {
        guard ble != nil || router != nil else { return nil }

        if let ble, let router, !matches(ble, router) {
            return nil
        }

        let identity = ble ?? router!
        guard normalizedMAC(identity.macAddress) != nil || identity.cid != nil else {
            return nil
        }
        return UnifiedDeviceRecord(
            bluetoothIdentity: ble,
            routerIdentity: router,
            preferredTransport: ble == nil ? .router : .bluetooth,
            normalizedMAC: normalizedMAC(ble?.macAddress) ?? normalizedMAC(router?.macAddress)
        )
    }

    public static func normalizedMAC(_ value: String?) -> String? {
        guard let value else { return nil }
        let hexadecimal = value.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
        guard hexadecimal.count == 12 else { return nil }
        return String(String.UnicodeScalarView(hexadecimal)).uppercased()
    }

    private static func matches(
        _ lhs: DeviceIdentitySnapshot,
        _ rhs: DeviceIdentitySnapshot
    ) -> Bool {
        let lhsMAC = normalizedMAC(lhs.macAddress)
        let rhsMAC = normalizedMAC(rhs.macAddress)
        if let lhsMAC, let rhsMAC {
            return lhsMAC == rhsMAC
        }
        if let lhsCID = lhs.cid, let rhsCID = rhs.cid {
            return lhsCID == rhsCID
        }
        return false
    }
}
