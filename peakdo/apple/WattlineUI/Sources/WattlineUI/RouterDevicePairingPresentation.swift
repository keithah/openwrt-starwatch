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
        case "connected": target.map { "Connected to \($0)" } ?? "Connected"
        case "failed": error == nil ? "Pairing failed." : "Pairing failed."
        default: "Ready"
        }
    }
}
