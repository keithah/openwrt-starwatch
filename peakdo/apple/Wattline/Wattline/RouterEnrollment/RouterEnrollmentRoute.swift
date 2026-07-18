import Foundation
import Observation
import WattlineNetwork

@MainActor
@Observable
final class RouterEnrollmentRoute: CustomStringConvertible, CustomDebugStringConvertible {
    private(set) var payload: RouterPairingPayload?

    nonisolated var description: String { "RouterEnrollmentRoute([REDACTED])" }
    nonisolated var debugDescription: String { description }

    @discardableResult
    func consume(_ url: URL) -> Bool {
        guard let input = try? RouterPairingInputParser.parse(url: url) else { return false }
        payload = input.payload
        return true
    }

    func clear() {
        payload = nil
    }
}
