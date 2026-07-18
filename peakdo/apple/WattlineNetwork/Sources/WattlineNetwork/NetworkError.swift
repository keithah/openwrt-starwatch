import Foundation

public enum NetworkError: Error, Equatable, Sendable {
    case invalidURL
    case unauthorized
    case httpStatus(Int, String)
    case decode(String)
    case streamEnded
    case unsupported(String)
    case timeout
    case transport(String)
}
