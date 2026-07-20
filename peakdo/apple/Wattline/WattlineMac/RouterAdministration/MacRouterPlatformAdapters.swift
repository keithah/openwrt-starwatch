import AppKit
import Foundation

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
    private let imageImporter: RouterPairingImageImporter

    init(
        route: RouterEnrollmentRoute,
        pasteboard: any MacPasteboardReading = SystemMacPasteboardReader(),
        imageSelector: any MacImageSelecting = SystemMacImageSelector(),
        recognizer: any QRCodeRecognizer = VisionQRCodeRecognizer()
    ) {
        self.route = route
        self.pasteboard = pasteboard
        self.imageSelector = imageSelector
        imageImporter = RouterPairingImageImporter(recognizer: recognizer, route: route)
    }

    func pastePairingLink() throws {
        guard let text = pasteboard.pairingText(), route.consume(text: text) else {
            throw MacRouterEnrollmentError.invalidPairingLink
        }
    }

    func importQRImage() async throws {
        guard let data = try imageSelector.imageData() else { return }
        try await imageImporter.importImage(data)
    }
}

enum MacRouterEnrollmentError: Error {
    case invalidPairingLink
}
