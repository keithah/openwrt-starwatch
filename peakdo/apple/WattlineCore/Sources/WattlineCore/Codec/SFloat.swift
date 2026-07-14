import Foundation

public enum FloatingPointValue: Equatable, Sendable {
    case finite(Double)
    case nan
    case positiveInfinity
    case negativeInfinity

    public var finiteValue: Double? {
        if case let .finite(value) = self { value } else { nil }
    }
}

public enum SFloat {
    public static func decode(_ data: Data) throws -> FloatingPointValue {
        let raw = try data.uint16LittleEndian(at: 0)
        switch raw {
        case 0x07FF: return .nan
        case 0x07FE: return .positiveInfinity
        case 0x0802: return .negativeInfinity
        default:
            let mantissa = Int16(bitPattern: (raw & 0x0800) == 0 ? raw & 0x0FFF : raw | 0xF000)
            let exponentBits = Int8(raw >> 12)
            let exponent = exponentBits < 8 ? exponentBits : exponentBits - 16
            return .finite(Double(mantissa) * pow(10, Double(exponent)))
        }
    }
}
