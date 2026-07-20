import Foundation
import WattlineNetwork
import WattlineUI

struct RouterAdministrationDemo: Equatable, CustomStringConvertible {
    var host: RouterHostMetadata
    var identity: RouterDeviceDTO
    var history: [RouterHistorySample]
    var settings: RouterSettings
    var pairingMode: RouterPairingMode
    var tokens: [RouterTokenMetadata]
    var devicePairingStatus: RouterDevicePairingStatus
    var advancedValues: RouterAdvancedValues
    var advancedVisibility: RouterAdvancedVisibility
    var rules: [RouterRuleDocument]

    var description: String { "RouterAdministrationDemo([REDACTED])" }

    static func fixture(
        now: Date = Date(timeIntervalSince1970: 1_721_260_800)
    ) throws -> RouterAdministrationDemo {
        let host = try RouterHostValidator.validate(
            "https://demo-router.local:8378",
            displayName: "Wattline Demo Router",
            reachability: .lan,
            allowsInsecureWAN: false,
            deviceID: "AA:BB:CC:DD:EE:FF",
            certificateFingerprint: String(repeating: "A1", count: 32),
            tokenID: "demo-client"
        )
        let identity: RouterDeviceDTO = try decode(#"""
        {
          "id":"AABBCCDDEEFF","model":"BP4SL3V2","hardware_revision":"2.1",
          "application_firmware":"1.8.4","ota_firmware":"1.8.4","cid":516,
          "features_raw":32767,
          "features":{"display":true,"factory_mode":true,"sleep":true,"shutdown":true,
            "battery_capacity":true,"dc_out_port":true,"dc_out_control":true,
            "dc_out_scheduler":true,"usb_port":true,"usb_power_limit":true,
            "usb_output_control":true,"dc_bypass":true,"dc_bypass_control":true,
            "usb_dc_input":true,"usb_dc_input_power":true,"running_mode":true,
            "barrier_free":true,"usb_firmware":true,"ble_pin":true},
          "available":{"current_time":true,"ota":true,"dc":true,"usbc":true},
          "mode":"app","connection":{"connected":true,"phase":"ready","reconnect":"idle"},
          "magic_dns_name":"demo-router.local"
        }
        """#)
        let settings: RouterSettings = try decode(#"""
        {
          "http":{"enabled":true,"addr4":"127.0.0.1","addr6":"::1","port":8377},
          "https":{"enabled":true,"addr4":"0.0.0.0","addr6":"::","port":8378},
          "tls":{"cert":"/etc/wattline/demo.crt","key":"/etc/wattline/demo.key","sha256":"A1A1A1A1"},
          "token_store":"/etc/wattline/tokens.json","pairing_ttl":"5m",
          "pairing_always_on":false,"advanced":true,
          "mdns":{"enabled":true,"interfaces":["br-lan"]},"wan_access":false,"ble_pin":""
        }
        """#)
        let tokens: [RouterTokenMetadata] = try decode(
            #"[{"id":"bootstrap","label":"Administrator","created_at":"2024-07-18T00:00:00Z","last_seen_at":"2024-07-18T01:00:00Z","bootstrap":true},{"id":"demo-client","label":"Demo iPhone","created_at":"2024-07-18T00:10:00Z","last_seen_at":"2024-07-18T01:05:00Z","bootstrap":false}]"#,
            dates: true
        )
        let known = try RouterRule(
            name: "low_battery",
            enabled: true,
            condition: .batteryLevel(op: .below, percent: 15),
            hold: RouterRuleDuration(.seconds(600)),
            hysteresisMargin: 5,
            actions: [.dcOff],
            confirmShutdown: false
        )
        let preset = try RouterPowerLossPreset(document: nil).reset(
            enabled: true,
            hold: RouterRuleDuration(.seconds(600)),
            confirmed: true
        )
        let unknownJSON: RouterJSONValue = .object([
            "name": .string("future_telemetry"),
            "enabled": .bool(true),
            "condition": .string("future_sensor"),
            "actions": .array([.string("future:preserved")]),
        ])
        let unknown = RawRouterRule(
            name: "future_telemetry",
            json: unknownJSON,
            canonicalJSON: #"{"actions":["future:preserved"],"condition":"future_sensor","enabled":true,"name":"future_telemetry"}"#
        )
        let history = try historySamples(now: now)
        return RouterAdministrationDemo(
            host: host,
            identity: identity,
            history: history,
            settings: settings,
            pairingMode: RouterPairingMode(
                open: true,
                expiresAt: now.addingTimeInterval(300),
                pin: nil
            ),
            tokens: tokens,
            devicePairingStatus: RouterDevicePairingStatus(
                stage: .paired,
                target: "10:20:30:40:50:60",
                devices: [
                    RouterPairableDevice(
                        mac: "10:20:30:40:50:60",
                        name: "Link-Power Demo",
                        rssi: -48,
                        paired: true
                    ),
                    RouterPairableDevice(
                        mac: "10:20:30:40:50:61",
                        name: "Nearby Link-Power",
                        rssi: -67,
                        paired: false
                    ),
                ],
                error: nil
            ),
            advancedValues: RouterAdvancedValues(
                bypassThresholdVolts: 19.5,
                clock: RouterAdvancedClockValue(
                    available: true,
                    deviceTime: "2024-07-18T00:00:00Z",
                    systemTime: "2024-07-18T00:00:02Z",
                    driftSeconds: -2
                ),
                runningMode: 0,
                barrierFreeEnabled: false,
                usbFirmware: RouterAdvancedUSBFirmwareValue(
                    raw: "010409", major: 1, minor: 4, patch: 9
                ),
                blePINUpdated: false
            ),
            advancedVisibility: RouterAdvancedVisibility(
                surfaces: Set(RouterAdvancedSurface.allCases),
                showsEnableAdvancedAffordance: false
            ),
            rules: [.known(preset), .known(known), .unknown(unknown)]
        )
    }

    static func applying(
        _ patch: RouterSettingsPatch,
        to settings: RouterSettings
    ) throws -> RouterSettings {
        let originalData = try JSONEncoder().encode(settings)
        let patchData = try JSONEncoder().encode(patch)
        guard var original = try JSONSerialization.jsonObject(with: originalData) as? [String: Any],
              let update = try JSONSerialization.jsonObject(with: patchData) as? [String: Any]
        else { throw RouterAdministrationDemoError.invalidFixture }
        merge(update, into: &original)
        // A Demo save acknowledges a PIN change but never retains the submitted secret.
        original["ble_pin"] = ""
        return try JSONDecoder().decode(
            RouterSettings.self,
            from: JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
        )
    }

    private static func historySamples(now: Date) throws -> [RouterHistorySample] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let values: [[String: Any]] = (0..<24).map { index in
            let progress = Double(index) / 23
            return [
                "at": formatter.string(from: now.addingTimeInterval(Double(index - 23) * 300)),
                "level": 42 + Int(progress * 36),
                "status": index < 8 ? -1 : index < 18 ? 1 : 0,
                "dc_w": index < 8 ? 28.0 : index < 18 ? 0.0 : 4.5,
                "typec_w": index < 8 ? 0.0 : index < 18 ? 52.0 : 0.0,
            ]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            [RouterHistorySample].self,
            from: JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        )
    }

    private static func decode<Value: Decodable>(
        _ json: String,
        dates: Bool = false
    ) throws -> Value {
        let decoder = JSONDecoder()
        if dates { decoder.dateDecodingStrategy = .iso8601 }
        return try decoder.decode(Value.self, from: Data(json.utf8))
    }

    private static func merge(_ update: [String: Any], into original: inout [String: Any]) {
        for (key, value) in update {
            if var nested = original[key] as? [String: Any],
               let nestedUpdate = value as? [String: Any]
            {
                merge(nestedUpdate, into: &nested)
                original[key] = nested
            } else {
                original[key] = value
            }
        }
    }
}

enum RouterAdministrationDemoError: Error {
    case externalAccess
    case invalidFixture
}

actor RouterAdministrationDemoCredentialBackend: RouterCredentialBackend {
    private var values: [String: Data] = [:]

    func read(account: String) async throws -> Data? { values[account] }
    func save(_ data: Data, account: String) async throws { values[account] = data }
    func delete(account: String) async throws { values[account] = nil }
}

final class RouterAdministrationDemoHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }
    func set(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
    func removeValue(forKey key: String) throws { lock.withLock { values[key] = nil } }
}

extension RouterConnectionModel {
    static func demo(
        credentials: any RouterCredentialBackend = RouterAdministrationDemoCredentialBackend(),
        hosts: any RouterHostKeyValueStore = RouterAdministrationDemoHostBackend()
    ) -> RouterConnectionModel {
        let credentialStore = RouterCredentialStore(backend: credentials)
        let hostStore = RouterHostStore(backend: hosts)
        return RouterConnectionModel(
            hostStore: hostStore,
            credentialStore: credentialStore,
            discovery: nil,
            tlsPromotionHTTPFactory: { _ in throw RouterAdministrationDemoError.externalAccess },
            enrollmentClientFactory: { _ in throw RouterAdministrationDemoError.externalAccess },
            transportFactory: { _, _ in throw RouterAdministrationDemoError.externalAccess }
        )
    }
}
