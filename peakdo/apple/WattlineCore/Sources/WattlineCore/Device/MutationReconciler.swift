import Foundation

public enum TelemetryUpdate: Equatable, Sendable {
    case dc(DCPortStatus)
    case typeC(TypeCPortStatus)
}

public enum MutationReconciler: Equatable, Sendable {
    case none
    case dcEnabled(Bool)
    case typeCOutput(Bool)
    case bypass(Bool)

    public func matches(_ update: TelemetryUpdate) -> Bool {
        switch (self, update) {
        case (.none, _):
            false
        case let (.dcEnabled(expected), .dc(status)):
            status.enabled == expected
        // API §3.4: output state lives in mode; enabled remains true when output is disabled.
        case let (.typeCOutput(expected), .typeC(status)):
            status.mode.map { mode in
                let outputIsOn = mode == .output || mode == .inputAndOutput
                return outputIsOn == expected
            } ?? false
        case let (.bypass(expected), .dc(status)):
            status.bypassOn == expected
        default:
            false
        }
    }
}
