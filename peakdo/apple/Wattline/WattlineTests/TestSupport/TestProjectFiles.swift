import Foundation

enum TestProjectFiles {
    static let projectDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TestSupport
        .deletingLastPathComponent() // WattlineTests
        .deletingLastPathComponent() // Wattline

    static func url(_ relativePath: String) -> URL {
        projectDirectory.appending(path: relativePath)
    }
}
