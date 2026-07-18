import Foundation

public struct RouterPairingInput: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let payload: RouterPairingPayload

    public var description: String { "RouterPairingInput([REDACTED])" }
    public var debugDescription: String { description }

    public init(payload: RouterPairingPayload) {
        self.payload = payload
    }
}

public enum RouterPairingInputParser {
    public static func parse(text: String) throws -> RouterPairingInput {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value) else {
            throw RouterPairingPayloadError.invalidPayload
        }
        return try parse(url: url)
    }

    public static func parse(url: URL) throws -> RouterPairingInput {
        RouterPairingInput(payload: try RouterPairingPayload.parse(url))
    }
}
