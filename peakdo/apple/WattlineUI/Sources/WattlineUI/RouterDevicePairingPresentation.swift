import Foundation

public struct RouterPairableDeviceValue: Equatable, Sendable {
    public let mac: String
    public let name: String
    public let rssi: Int
    public let paired: Bool

    public init(mac: String, name: String, rssi: Int, paired: Bool) {
        self.mac = mac
        self.name = name
        self.rssi = rssi
        self.paired = paired
    }
}

public struct RouterPairingRow: Equatable, Sendable {
    public let mac: String
    public let title: String
    public let detail: String
    public let paired: Bool
}

public struct RouterDevicePairingActions: Equatable, Sendable {
    public let showsScan: Bool
    public let showsPair: Bool
    public let showsUnpair: Bool

    public init(showsScan: Bool, showsPair: Bool, showsUnpair: Bool) {
        self.showsScan = showsScan
        self.showsPair = showsPair
        self.showsUnpair = showsUnpair
    }
}

public enum RouterDevicePairingPresentation {
    public static func rows(
        stage _: String,
        devices: [RouterPairableDeviceValue]
    ) -> [RouterPairingRow] {
        devices.sorted {
            let ordering = $0.name.localizedCaseInsensitiveCompare($1.name)
            return ordering == .orderedSame ? $0.mac < $1.mac : ordering == .orderedAscending
        }.map {
            RouterPairingRow(
                mac: $0.mac,
                title: $0.name.isEmpty ? $0.mac : $0.name,
                detail: "\($0.rssi) dBm" + ($0.paired ? " · Paired" : ""),
                paired: $0.paired
            )
        }
    }

    public static func statusText(stage: String, target: String?, error: String?) -> String {
        switch stage {
        case "scanning": "Scanning for Link-Power devices…"
        case "pairing": target.map { "Pairing \($0)…" } ?? "Pairing…"
        case "paired": target.map { "Paired with \($0)" } ?? "Paired"
        case "error": error == nil ? "Pairing failed." : "Pairing failed."
        default: "Ready"
        }
    }

    public static func isValidPIN(_ value: String) -> Bool {
        value.isEmpty || ((1...6).contains(value.utf8.count)
            && value.utf8.allSatisfy { (48...57).contains($0) })
    }

    public static func actions(
        isBusy: Bool,
        hasSelection: Bool
    ) -> RouterDevicePairingActions {
        .init(
            showsScan: !isBusy,
            showsPair: !isBusy && hasSelection,
            showsUnpair: !isBusy
        )
    }
}
