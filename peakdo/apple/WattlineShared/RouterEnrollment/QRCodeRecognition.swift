#if os(iOS)
import AVFoundation
#endif
import Foundation
import Vision
import WattlineNetwork

protocol QRCodeRecognizer: Sendable {
    func payload(from imageData: Data) async throws -> String
}

enum QRCodeRecognitionError: Error, Equatable {
    case noPairingCode
}

struct VisionQRCodeRecognizer: QRCodeRecognizer {
    func payload(from imageData: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(data: imageData)
            try handler.perform([request])
            guard let value = request.results?.compactMap(\.payloadStringValue).first else {
                throw QRCodeRecognitionError.noPairingCode
            }
            return value
        }.value
    }
}

@MainActor
final class RouterPairingImageImporter {
    private let recognizer: any QRCodeRecognizer
    private let route: RouterEnrollmentRoute

    init(recognizer: any QRCodeRecognizer, route: RouterEnrollmentRoute) {
        self.recognizer = recognizer
        self.route = route
    }

    func importImage(_ data: Data) async throws {
        let value = try await recognizer.payload(from: data)
        guard route.consume(text: value) else {
            throw RouterPairingPayloadError.invalidPayload
        }
    }
}

#if os(iOS)
enum CameraAuthorizationStatus: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
}

protocol CameraAuthorizationAdapter: Sendable {
    func authorizationStatus() async -> CameraAuthorizationStatus
    func requestAccess() async -> Bool
}

struct SystemCameraAuthorizationAdapter: CameraAuthorizationAdapter {
    func authorizationStatus() async -> CameraAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

struct RouterCameraAccessController: Sendable {
    private let adapter: any CameraAuthorizationAdapter

    init(adapter: any CameraAuthorizationAdapter) {
        self.adapter = adapter
    }

    func authorizeForScan() async -> Bool {
        switch await adapter.authorizationStatus() {
        case .authorized: true
        case .denied: false
        case .notDetermined: await adapter.requestAccess()
        }
    }
}
#endif
