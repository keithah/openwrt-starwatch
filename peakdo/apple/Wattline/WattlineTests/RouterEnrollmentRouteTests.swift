import Foundation
import WattlineCore
import WattlineNetwork
import XCTest
@testable import Wattline

@MainActor
final class RouterEnrollmentRouteTests: XCTestCase {
    func testNewPairingLinkReplacesPriorSecretAndClearRemovesIt() throws {
        let first = try XCTUnwrap(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=first.local&http=8377&pin=123456"
        ))
        let second = try XCTUnwrap(URL(string:
            "wattline://pair?v=1&id=AABBCCDDEEFF&host=second.local&http=8377&pin=654321"
        ))
        let route = RouterEnrollmentRoute()

        XCTAssertTrue(route.consume(first))
        XCTAssertEqual(route.payload?.deviceID, "DC045AEB722B")
        XCTAssertTrue(route.consume(second))
        XCTAssertEqual(route.payload?.deviceID, "AABBCCDDEEFF")
        XCTAssertFalse(String(describing: route).contains("654321"))

        route.clear()
        XCTAssertNil(route.payload)
    }

    func testPairingDeepLinkMovesAppToScanAndPublishesEphemeralEnrollment() {
        let model = makeModel(onboardingComplete: true)

        model.handleDeepLink(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456"
        )!)

        XCTAssertEqual(model.route, .scan)
        XCTAssertEqual(model.routerEnrollmentRoute.payload?.deviceID, "DC045AEB722B")
    }

    func testPairingDeepLinkDuringOnboardingDefersPayloadWithoutLeavingOnboarding() {
        let model = makeModel(onboardingComplete: false)

        model.handleDeepLink(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456"
        )!)

        XCTAssertEqual(model.route, .onboarding)
        XCTAssertEqual(model.routerEnrollmentRoute.payload?.deviceID, "DC045AEB722B")

        model.requestBluetoothAfterPriming()

        XCTAssertEqual(model.route, .scan)
        XCTAssertEqual(model.routerEnrollmentRoute.payload?.deviceID, "DC045AEB722B")
    }

    func testRouteConsumesWhitespacePaddedPairingText() {
        let route = RouterEnrollmentRoute()

        XCTAssertTrue(route.consume(text:
            "  wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456\n"
        ))
        XCTAssertEqual(route.payload?.deviceID, "DC045AEB722B")
    }

    func testRouteAcceptsAlreadyParsedPairingInput() throws {
        let route = RouterEnrollmentRoute()
        let input = try RouterPairingInputParser.parse(text:
            "  wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456\n"
        )

        XCTAssertTrue(route.consume(input))
        XCTAssertEqual(route.payload?.deviceID, "DC045AEB722B")
    }

    private func makeModel(onboardingComplete: Bool) -> AppModel {
        let suiteName = "RouterEnrollmentRouteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let persistence = AppPersistence(defaults: defaults)
        persistence.onboardingComplete = onboardingComplete
        return AppModel(
            persistence: persistence,
            transportFactory: { EnrollmentRouteNoopTransport() },
            snapshotCoordinator: nil,
            widgetReloadAdapter: nil,
            liveActivityAdapter: EnrollmentRouteNoopActivityAdapter(),
            routerConnections: RouterConnectionModel(
                hostStore: RouterHostStore(backend: EnrollmentRouteHostBackend()),
                credentialStore: RouterCredentialStore(backend: EnrollmentRouteCredentialBackend()),
                enrollmentClientFactory: { _ in throw NetworkError.unsupported("not used") },
                transportFactory: { _, _ in EnrollmentRouteNoopTransport() }
            )
        )
    }

    func testNonPairingURLDoesNotReplaceCurrentRoute() throws {
        let route = RouterEnrollmentRoute()
        XCTAssertTrue(route.consume(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=first.local&http=8377&pin=123456"
        )!))

        XCTAssertFalse(route.consume(URL(string: "wattline://dashboard")!))
        XCTAssertEqual(route.payload?.deviceID, "DC045AEB722B")
    }

    func testImageImporterPublishesRecognizedPairingPayload() async throws {
        let route = RouterEnrollmentRoute()
        let recognizer = EnrollmentRouteQRRecognizer(payload:
            "  wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456\n"
        )
        let importer = RouterPairingImageImporter(recognizer: recognizer, route: route)

        try await importer.importImage(Data([0x01, 0x02]))

        XCTAssertEqual(route.payload?.deviceID, "DC045AEB722B")
        let receivedData = await recognizer.receivedData
        XCTAssertEqual(receivedData, Data([0x01, 0x02]))
    }

    func testCameraPermissionIsRequestedOnlyWhenScanBegins() async {
        let adapter = EnrollmentRouteCameraAuthorizationAdapter()
        let access = RouterCameraAccessController(adapter: adapter)
        let requestCountBeforeScan = await adapter.requestCount
        XCTAssertEqual(requestCountBeforeScan, 0)

        let granted = await access.authorizeForScan()

        XCTAssertTrue(granted)
        let requestCountAfterScan = await adapter.requestCount
        XCTAssertEqual(requestCountAfterScan, 1)
    }
}

private actor EnrollmentRouteNoopTransport: DeviceTransport {
    nonisolated let events = AsyncStream<DeviceEvent> { $0.finish() }
    func startScan() async throws {}
    func stopScan() async {}
    func connect(to id: UUID, scope: DeviceConnectionScope) async throws {}
    func disconnect() async {}
    func perform(_ command: DeviceCommand) async throws -> CommandOutcome { .sent }
    func refreshTelemetry() async throws {}
    func synchronizeDeviceTime() async throws {}
    func readDeviceTimeIfSupported() async throws -> Date? { nil }
}

private struct EnrollmentRouteNoopActivityAdapter: LiveActivityAdapter {
    func request(state: WattlineActivityAttributes.ContentState) async throws {}
    func update(state: WattlineActivityAttributes.ContentState) async throws {}
    func end() async {}
}

private final class EnrollmentRouteHostBackend: RouterHostKeyValueStore, @unchecked Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data, forKey key: String) throws {}
    func removeValue(forKey key: String) {}
}

private actor EnrollmentRouteCredentialBackend: RouterCredentialBackend {
    func read(account: String) async throws -> Data? { nil }
    func save(_ data: Data, account: String) async throws {}
    func delete(account: String) async throws {}
}

private actor EnrollmentRouteQRRecognizer: QRCodeRecognizer {
    private let payload: String
    private(set) var receivedData: Data?
    init(payload: String) { self.payload = payload }
    func payload(from imageData: Data) async throws -> String {
        receivedData = imageData
        return payload
    }
}

private actor EnrollmentRouteCameraAuthorizationAdapter: CameraAuthorizationAdapter {
    private(set) var requestCount = 0
    func authorizationStatus() async -> CameraAuthorizationStatus { .notDetermined }
    func requestAccess() async -> Bool {
        requestCount += 1
        return true
    }
}
