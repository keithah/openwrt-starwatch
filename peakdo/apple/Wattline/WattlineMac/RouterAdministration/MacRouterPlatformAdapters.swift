import AppKit
import Foundation
import WattlineNetwork

@MainActor
protocol MacPasteboardReading {
    func pairingText() -> String?
}

struct SystemMacPasteboardReader: MacPasteboardReading {
    func pairingText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}

@MainActor
protocol MacImageSelecting {
    func imageData() throws -> Data?
}

struct SystemMacImageSelector: MacImageSelecting {
    func imageData() throws -> Data? {
        let panel = NSOpenPanel()
        panel.title = "Import Wattline pairing QR"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try Data(contentsOf: url)
    }
}

@MainActor
final class MacRouterEnrollmentAdapter {
    private let route: RouterEnrollmentRoute
    private let pasteboard: any MacPasteboardReading
    private let imageSelector: any MacImageSelecting
    private let recognizer: any QRCodeRecognizer

    init(
        route: RouterEnrollmentRoute,
        pasteboard: any MacPasteboardReading = SystemMacPasteboardReader(),
        imageSelector: any MacImageSelecting = SystemMacImageSelector(),
        recognizer: any QRCodeRecognizer = VisionQRCodeRecognizer()
    ) {
        self.route = route
        self.pasteboard = pasteboard
        self.imageSelector = imageSelector
        self.recognizer = recognizer
    }

    func pastePairingLink() throws {
        guard let text = pasteboard.pairingText(), route.consume(text: text) else {
            throw MacRouterEnrollmentError.invalidPairingLink
        }
    }

    func pairingInputFromQRImage() async throws -> RouterPairingInput? {
        guard let data = try imageSelector.imageData() else { return nil }
        let value = try await recognizer.payload(from: data)
        return try RouterPairingInputParser.parse(text: value)
    }
}

enum MacRouterEnrollmentError: Error {
    case invalidPairingLink
}
