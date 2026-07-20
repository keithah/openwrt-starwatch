import Foundation
import XCTest
@testable import WattlineMac

@MainActor
final class MacRouterEnrollmentLifecycleTests: XCTestCase {
    func testInvalidatingForPayloadReplacementPreservesNewRouteSecret() throws {
        let route = RouterEnrollmentRoute()
        XCTAssertTrue(route.consume(try pairingURL(pin: "123456")))
        let lifecycle = MacRouterEnrollmentLifecycle(route: route)
        let generation = lifecycle.beginSubmission()

        lifecycle.invalidatePreservingRoute()

        XCTAssertNotNil(route.payload)
        XCTAssertFalse(lifecycle.isSubmitting)
        XCTAssertFalse(lifecycle.isCurrent(generation))
    }

    func testLifecycleExitClearsPairingRouteSecretAndCancelsOwnedTask() throws {
        let route = RouterEnrollmentRoute()
        XCTAssertTrue(route.consume(try pairingURL(pin: "123456")))
        let lifecycle = MacRouterEnrollmentLifecycle(route: route)
        let generation = lifecycle.beginSubmission()
        let task = Task<Void, Never> { await Task.yield() }
        lifecycle.own(task, generation: generation)

        lifecycle.invalidateAndClearRoute()

        XCTAssertNil(route.payload)
        XCTAssertTrue(task.isCancelled)
        XCTAssertFalse(lifecycle.isSubmitting)
        XCTAssertFalse(lifecycle.isCurrent(generation))
    }

    func testStaleCompletionCannotPublishOverCurrentGeneration() {
        let lifecycle = MacRouterEnrollmentLifecycle(route: RouterEnrollmentRoute())
        let staleGeneration = lifecycle.beginSubmission()
        lifecycle.invalidatePreservingRoute()
        let currentGeneration = lifecycle.beginSubmission()
        var publications: [String] = []

        if lifecycle.finish(generation: staleGeneration) {
            publications.append("stale")
        }

        XCTAssertTrue(lifecycle.isSubmitting)
        XCTAssertTrue(lifecycle.isCurrent(currentGeneration))
        XCTAssertEqual(publications, [])

        if lifecycle.finish(generation: currentGeneration) {
            publications.append("current")
        }

        XCTAssertFalse(lifecycle.isSubmitting)
        XCTAssertEqual(publications, ["current"])
    }

    func testStaleSourceOperationCannotRestoreRouteAfterExit() throws {
        let route = RouterEnrollmentRoute()
        let lifecycle = MacRouterEnrollmentLifecycle(route: route)
        let generation = lifecycle.beginSourceOperation()
        let task = Task<Void, Never> { await Task.yield() }
        lifecycle.own(task, generation: generation)

        lifecycle.invalidateAndClearRoute()
        if lifecycle.finish(generation: generation) {
            route.consume(try pairingURL(pin: "654321"))
        }

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(route.payload)
    }

    func testImageAdapterReturnsInputWithoutPublishingRoute() async throws {
        let route = RouterEnrollmentRoute()
        let adapter = MacRouterEnrollmentAdapter(
            route: route,
            pasteboard: LifecyclePasteboard(),
            imageSelector: LifecycleImageSelector(),
            recognizer: LifecycleQRCodeRecognizer()
        )

        let optionalInput = try await adapter.pairingInputFromQRImage()
        let input = try XCTUnwrap(optionalInput)

        XCTAssertEqual(input.payload.deviceID, "DC045AEB722B")
        XCTAssertNil(route.payload)
    }

    private func pairingURL(pin: String) throws -> URL {
        try XCTUnwrap(URL(string:
            "wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=\(pin)"
        ))
    }
}

@MainActor
private struct LifecyclePasteboard: MacPasteboardReading {
    func pairingText() -> String? { nil }
}

@MainActor
private struct LifecycleImageSelector: MacImageSelecting {
    func imageData() throws -> Data? { Data([0x01]) }
}

private struct LifecycleQRCodeRecognizer: QRCodeRecognizer {
    func payload(from imageData: Data) async throws -> String {
        "wattline://pair?v=1&id=DC045AEB722B&host=router.local&http=8377&pin=123456"
    }
}
