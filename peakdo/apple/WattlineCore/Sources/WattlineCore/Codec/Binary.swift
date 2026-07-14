import Foundation

public enum CodecError: Error, Equatable, Sendable {
    case truncated
    case commandEchoMismatch(expected: UInt8, actual: UInt8)
    case actionEchoMismatch(expected: UInt8, actual: UInt8)
    case rejectedResult(UInt8)
}

extension Data {
    func byte(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset < count else { throw CodecError.truncated }
        return self[index(startIndex, offsetBy: offset)]
    }

    func uint16LittleEndian(at offset: Int) throws -> UInt16 {
        UInt16(try byte(at: offset))
            | UInt16(try byte(at: offset + 1)) << 8
    }

    func uint32LittleEndian(at offset: Int) throws -> UInt32 {
        UInt32(try byte(at: offset))
            | UInt32(try byte(at: offset + 1)) << 8
            | UInt32(try byte(at: offset + 2)) << 16
            | UInt32(try byte(at: offset + 3)) << 24
    }
}
