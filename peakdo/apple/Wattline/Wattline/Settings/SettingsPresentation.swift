import WattlineCore

struct SettingsIdentityPresentation: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        let label: String
        let value: String

        var id: String { label }
    }

    let rows: [Row]
    let isStale: Bool

    init(identity: DeviceIdentitySnapshot?, isConnected: Bool) {
        guard let identity else {
            rows = []
            isStale = false
            return
        }

        rows = [
            identity.modelNumber.map { Row(label: "Model", value: $0) },
            identity.hardwareRevision.map { Row(label: "Hardware / Variant", value: $0) },
            identity.appFirmwareRevision.map { Row(label: "App Firmware", value: $0) },
            identity.otaFirmwareRevision.map { Row(label: "OTA Bootloader", value: $0) },
            identity.macAddress.map { Row(label: "MAC Address", value: $0) },
        ].compactMap { $0 }
        isStale = !isConnected
    }
}
