import Foundation
import XCTest
@testable import WattlineNetwork

final class RouterRulesTests: XCTestCase {
    func testDocumentedLowBatteryFixtureDecodesAndRoundTripsCanonically() throws {
        let data = Data(#"{"name":"low_battery","enabled":true,"condition":"battery_level","op":"below","percent":15,"hold":600000000000,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#.utf8)
        let document = try JSONDecoder().decode(RouterRuleDocument.self, from: data)
        guard case let .known(rule) = document else { return XCTFail("expected known rule") }
        XCTAssertEqual(rule.name, "low_battery")
        XCTAssertEqual(rule.condition, .batteryLevel(op: .below, percent: 15))
        XCTAssertEqual(try rule.hold.nanoseconds(), 600_000_000_000)
        XCTAssertEqual(rule.hysteresisMargin, 5)
        XCTAssertEqual(rule.actions, [.dcOff])
        XCTAssertFalse(rule.confirmShutdown)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try JSONDecoder().decode(RouterRuleDocument.self, from: encoder.encode(rule)),
            document
        )
    }

    func testAllConditionFamiliesAndActionsDecode() throws {
        let fixtures = [
            #"{"name":"input","enabled":true,"condition":"input_power","state":"present","hold":0,"hysteresis_margin":0,"actions":["dc_on","dc_off","usbc_on","usbc_off","bypass_on","bypass_off","restart"],"confirm_shutdown":false}"#,
            #"{"name":"port","enabled":true,"condition":"port_power","port":"usbc","op":"above","watts":45.5,"hold":1000000000,"hysteresis_margin":2,"repeat_every":30000000000,"actions":["webhook:https://example.test/hook"],"confirm_shutdown":false}"#,
            #"{"name":"cron","enabled":false,"condition":"schedule","cron":"0 2 * * 1","hold":0,"hysteresis_margin":5,"actions":["shutdown"],"confirm_shutdown":true}"#,
        ]
        let decoded = try fixtures.map { try JSONDecoder().decode(RouterRuleDocument.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.count, 3)
        XCTAssertTrue(decoded.allSatisfy { if case .known = $0 { true } else { false } })
    }

    func testDurationConversionRejectsOverflowAndSubNanosecondValues() throws {
        XCTAssertThrowsError(try RouterRuleDuration(.seconds(Int64.max)).nanoseconds())
        XCTAssertThrowsError(try RouterRuleDuration(
            .seconds(1) + .init(secondsComponent: 0, attosecondsComponent: 1)
        ).nanoseconds())
        XCTAssertThrowsError(try RouterRuleDuration(nanoseconds: -1))
    }

    func testZeroHysteresisNormalizesToFiveAndZeroRepeatIsOmitted() throws {
        let rule = try RouterRule(name: "power", enabled: true,
            condition: .inputPower(state: .absent), hold: .init(nanoseconds: 0),
            hysteresisMargin: 0, repeatEvery: .init(nanoseconds: 0),
            actions: [.dcOff], confirmShutdown: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        XCTAssertEqual(object["hysteresis_margin"] as? Int, 5)
        XCTAssertNil(object["repeat_every"])
    }

    func testUnknownAdditiveFieldPreservesEntireRawDocumentAndCannotMutate() throws {
        let fixture = #"{"name":"future","enabled":true,"condition":"input_power","state":"absent","future_window":3,"hold":0,"hysteresis_margin":5,"actions":["shutdown","future:opaque"],"confirm_shutdown":true}"#
        let decoded = try JSONDecoder().decode(RouterRuleDocument.self, from: Data(fixture.utf8))
        guard case let .unknown(raw) = decoded else { return XCTFail("expected lossless fallback") }
        XCTAssertEqual(
            raw.canonicalJSON,
            #"{"actions":["shutdown","future:opaque"],"condition":"input_power","confirm_shutdown":true,"enabled":true,"future_window":3,"hold":0,"hysteresis_margin":5,"name":"future","state":"absent"}"#
        )
        XCTAssertThrowsError(try JSONEncoder().encode(decoded))
    }

    func testUnknownConditionAndActionIndependentlyUseLosslessFallback() throws {
        let fixtures = [
            #"{"name":"future","enabled":true,"condition":"solar_window","hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
            #"{"name":"future","enabled":true,"condition":"input_power","state":"absent","hold":0,"hysteresis_margin":5,"actions":["future:opaque"],"confirm_shutdown":false}"#,
            #"{"name":"future","enabled":true,"condition":"input_power","state":"absent","hold":0,"hysteresis_margin":5,"actions":["webhook:ftp://example.test/hook"],"confirm_shutdown":false}"#,
        ]
        for fixture in fixtures {
            let document = try JSONDecoder().decode(
                RouterRuleDocument.self,
                from: Data(fixture.utf8)
            )
            guard case let .unknown(raw) = document else {
                return XCTFail("expected lossless fallback")
            }
            XCTAssertEqual(
                try JSONDecoder().decode(RouterJSONValue.self, from: Data(raw.canonicalJSON.utf8)),
                raw.json
            )
        }
    }

    func testFutureVariantsWithinKnownConditionFamiliesRemainLosslessUnknowns() throws {
        let fixtures: [(label: String, json: String, additive: String?)] = [
            (
                "input state",
                #"{"name":"future","enabled":true,"condition":"input_power","state":"unstable","hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                nil
            ),
            (
                "input state plus additive",
                #"{"name":"future","enabled":true,"condition":"input_power","state":"unstable","future_window":3,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                #""future_window":3"#
            ),
            (
                "battery op",
                #"{"name":"future","enabled":true,"condition":"battery_level","op":"at_most","percent":15,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                nil
            ),
            (
                "battery op plus additive",
                #"{"name":"future","enabled":true,"condition":"battery_level","op":"at_most","percent":15,"future_window":3,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                #""future_window":3"#
            ),
            (
                "port op",
                #"{"name":"future","enabled":true,"condition":"port_power","port":"dc","op":"at_least","watts":5,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                nil
            ),
            (
                "port op plus additive",
                #"{"name":"future","enabled":true,"condition":"port_power","port":"dc","op":"at_least","watts":5,"future_window":3,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                #""future_window":3"#
            ),
            (
                "port value",
                #"{"name":"future","enabled":true,"condition":"port_power","port":"wireless","op":"above","watts":5,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                nil
            ),
            (
                "port value plus additive",
                #"{"name":"future","enabled":true,"condition":"port_power","port":"wireless","op":"above","watts":5,"future_window":3,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
                #""future_window":3"#
            ),
        ]

        for fixture in fixtures {
            let data = Data(fixture.json.utf8)
            let original = try JSONDecoder().decode(RouterJSONValue.self, from: data)
            let document = try JSONDecoder().decode(RouterRuleDocument.self, from: data)
            guard case let .unknown(raw) = document else {
                return XCTFail("expected unknown for \(fixture.label)")
            }
            XCTAssertEqual(raw.json, original, fixture.label)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    RouterJSONValue.self,
                    from: Data(raw.canonicalJSON.utf8)
                ),
                original,
                fixture.label
            )
            if let additive = fixture.additive {
                XCTAssertTrue(raw.canonicalJSON.contains(additive), fixture.label)
            }
        }
    }

    func testUnknownLargeIntegerAndDecimalRemainExactInCanonicalJSON() throws {
        let fixture = #"{"name":"future","enabled":true,"condition":"input_power","state":"absent","future_integer":9007199254740993,"future_decimal":0.1234567890123456789012345678,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#
        let document = try JSONDecoder().decode(
            RouterRuleDocument.self,
            from: Data(fixture.utf8)
        )
        guard case let .unknown(raw) = document else {
            return XCTFail("expected lossless fallback")
        }
        XCTAssertTrue(raw.canonicalJSON.contains(#""future_integer":9007199254740993"#))
        XCTAssertTrue(
            raw.canonicalJSON.contains(
                #""future_decimal":0.1234567890123456789012345678"#
            )
        )
    }

    func testExactlyRepresentableNumbersRetainNumberCaseCompatibility() throws {
        let value = try JSONDecoder().decode(
            RouterJSONValue.self,
            from: Data(#"{"whole":3,"fraction":45.5}"#.utf8)
        )
        guard case let .object(object) = value else {
            return XCTFail("expected object")
        }
        XCTAssertEqual(object["whole"], .number(3))
        XCTAssertEqual(object["fraction"], .number(45.5))
    }

    func testInt64MaximumDurationDecodesAndRoundTripsExactly() throws {
        let fixture = #"{"name":"maximum_hold","enabled":true,"condition":"input_power","state":"absent","hold":9223372036854775807,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#
        let document = try JSONDecoder().decode(
            RouterRuleDocument.self,
            from: Data(fixture.utf8)
        )
        guard case let .known(rule) = document else {
            return XCTFail("expected known rule")
        }
        XCTAssertEqual(try rule.hold.nanoseconds(), Int64.max)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(rule)
        XCTAssertTrue(
            String(decoding: encoded, as: UTF8.self)
                .contains(#""hold":9223372036854775807"#)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RouterRuleDocument.self, from: encoded),
            document
        )
    }

    func testUnknownRulesRemainReadableButInvalidKnownValuesAreRejected() async throws {
        let future = #"{"name":"future","enabled":true,"condition":"input_power","state":"absent","future_window":3,"hold":0,"hysteresis_margin":5,"actions":["shutdown","future:opaque"],"confirm_shutdown":true}"#
        let f = try await fixture([ScriptedRouterHTTPClient.ok("[\(future)]")])
        let documents = try await f.client.rules()
        guard case let .unknown(raw) = try XCTUnwrap(documents.first) else {
            return XCTFail("expected lossless fallback")
        }
        XCTAssertEqual(raw.name, "future")

        for malformed in [
            #"{"name":"bad","enabled":true,"condition":"battery_level","op":"below","percent":101,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
            #"{"name":"bad","enabled":true,"condition":"port_power","port":"dc","op":"above","watts":-1,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
            #"{"name":"bad","enabled":true,"condition":"schedule","cron":"0 2 * *","hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
            #"{"name":"bad","enabled":true,"condition":"input_power","state":"absent","hold":0,"hysteresis_margin":5,"actions":["shutdown"],"confirm_shutdown":false}"#,
            #"{"name":"bad","enabled":true,"condition":"input_power","state":3,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
            #"{"name":"bad","enabled":true,"condition":"battery_level","op":3,"percent":15,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
            #"{"name":"bad","enabled":true,"condition":"port_power","port":3,"op":"above","watts":5,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
            #"{"name":"bad","enabled":true,"condition":"port_power","port":"dc","op":3,"watts":5,"hold":0,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(RouterRuleDocument.self, from: Data(malformed.utf8))
            )
        }
    }

    func testCRUDUsesCanonicalRoutesURLNameWinsAndEveryMutationRelists() async throws {
        let f = try await fixture([
            ScriptedRouterHTTPClient.ok("[]"),
            ScriptedRouterHTTPClient.ok(lowBatteryJSON),
            ScriptedRouterHTTPClient.ok("[\(lowBatteryJSON)]"),
            ScriptedRouterHTTPClient.ok(
                lowBatteryJSON.replacingOccurrences(of: "low_battery", with: "url_name")
            ),
            ScriptedRouterHTTPClient.ok("[]"),
            ScriptedRouterHTTPClient.ok(#"{"deleted":"url_name"}"#),
            ScriptedRouterHTTPClient.ok("[]"),
        ])
        let knownRule = try known(lowBatteryJSON)
        let initial = try await f.client.rules()
        XCTAssertEqual(initial, [])
        let created = try await f.client.createRule(knownRule)
        let updated = try await f.client.updateRule(named: "url_name", rule: knownRule)
        let deleted = try await f.client.deleteRule(named: "url_name")
        XCTAssertEqual(created.stored, knownRule)
        XCTAssertEqual(updated.stored?.name, "url_name")
        XCTAssertEqual(deleted.deletedName, "url_name")
        XCTAssertEqual(f.http.calls.map { "\($0.method) \($0.path)" }, [
            "GET /api/v1/rules",
            "POST /api/v1/rules", "GET /api/v1/rules",
            "PUT /api/v1/rules/url_name", "GET /api/v1/rules",
            "DELETE /api/v1/rules/url_name", "GET /api/v1/rules",
        ])
        XCTAssertFalse(f.http.calls.contains { $0.path.contains("/device/action") })
        XCTAssertEqual(f.http.calls.filter { $0.method == "GET" }.map(\.token),
                       ["client-token", "client-token", "client-token", "client-token"])
        XCTAssertEqual(f.http.calls.filter { $0.method != "GET" }.map(\.token),
                       ["admin-token", "admin-token", "admin-token"])
        XCTAssertNil(f.http.calls[5].body)
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(f.http.calls[1].body), as: UTF8.self),
            #"{"actions":["dc_off"],"condition":"battery_level","confirm_shutdown":false,"enabled":true,"hold":600000000000,"hysteresis_margin":5,"name":"low_battery","op":"below","percent":15}"#
        )
    }

    func testUpdatePercentEncodesOnePathSegmentAndURLNameWinsBodyResponseAndList() async throws {
        let urlName = "odd/name ?#%"
        let storedJSON = lowBatteryJSON.replacingOccurrences(
            of: "low_battery",
            with: urlName
        )
        let f = try await fixture([
            ScriptedRouterHTTPClient.ok(storedJSON),
            ScriptedRouterHTTPClient.ok("[\(storedJSON)]"),
        ])
        let result = try await f.client.updateRule(named: urlName, rule: known(lowBatteryJSON))

        XCTAssertEqual(f.http.calls.map(\.path), [
            "/api/v1/rules/odd%2Fname%20%3F%23%25",
            "/api/v1/rules",
        ])
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(f.http.calls[0].body))
                as? [String: Any]
        )
        XCTAssertEqual(body["name"] as? String, urlName)
        XCTAssertEqual(result.stored?.name, urlName)
        guard case let .known(listed) = try XCTUnwrap(result.rules.first) else {
            return XCTFail("expected known URL-named rule")
        }
        XCTAssertEqual(listed.name, urlName)
    }

    func testDeletePercentEncodesPathHasNoBodyAndRejectsDeletedNameMismatch() async throws {
        let f = try await fixture([
            ScriptedRouterHTTPClient.ok(#"{"deleted":"different"}"#),
        ])
        await XCTAssertRouterRuleThrowsError(
            try await f.client.deleteRule(named: "odd/name")
        ) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }
        XCTAssertEqual(f.http.calls.map(\.path), ["/api/v1/rules/odd%2Fname"])
        XCTAssertNil(f.http.calls[0].body)
    }

    func testMalformedListAndStoredResponsesAreRejectedWithoutRelisting() async throws {
        let malformedList = try await fixture([ScriptedRouterHTTPClient.ok("{}")])
        await XCTAssertRouterRuleThrowsError(try await malformedList.client.rules()) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }

        let malformedStored = try await fixture([ScriptedRouterHTTPClient.ok("[]")])
        await XCTAssertRouterRuleThrowsError(
            try await malformedStored.client.createRule(known(lowBatteryJSON))
        ) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }
        XCTAssertEqual(malformedStored.http.calls.map(\.method), ["POST"])
    }

    func testUnknownStoredRuleIsRejectedAtCreateAndUpdateMutationBoundaries() async throws {
        let future = #"{"name":"low_battery","enabled":true,"condition":"input_power","state":"absent","future_window":3,"hold":0,"hysteresis_margin":5,"actions":["future:opaque"],"confirm_shutdown":false}"#
        let f = try await fixture([
            ScriptedRouterHTTPClient.ok(future),
            ScriptedRouterHTTPClient.ok(
                future.replacingOccurrences(of: "low_battery", with: "url_name")
            ),
        ])
        let rule = try known(lowBatteryJSON)
        await XCTAssertRouterRuleThrowsError(try await f.client.createRule(rule)) {
            XCTAssertEqual($0 as? RouterRuleValidationError, .unknownRuleCannotMutate)
        }
        await XCTAssertRouterRuleThrowsError(
            try await f.client.updateRule(named: "url_name", rule: rule)
        ) {
            XCTAssertEqual($0 as? RouterRuleValidationError, .unknownRuleCannotMutate)
        }
        XCTAssertEqual(f.http.calls.map(\.method), ["POST", "PUT"])
    }

    func testUpdateRejectsStoredBodyNameWhenItDoesNotMatchURLName() async throws {
        let f = try await fixture([ScriptedRouterHTTPClient.ok(lowBatteryJSON)])
        await XCTAssertRouterRuleThrowsError(
            try await f.client.updateRule(
                named: "url_name",
                rule: known(lowBatteryJSON)
            )
        ) {
            XCTAssertEqual($0 as? RouterAdministrationError, .invalidResponse)
        }
        XCTAssertEqual(f.http.calls.map(\.method), ["PUT"])
    }

    func testReplacementCancelsOldRulesRead() async throws {
        let oldHTTP = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok("[]")],
            gateRequests: true
        )
        let oldEndpoint = endpoint(host: "old.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("client-token", for: oldEndpoint, role: .client)
        let client = RouterAdministrationClient(credentials: credentials) { _ in oldHTTP }
        try await client.attach(endpoint: oldEndpoint)

        let read = Task { try await client.rules() }
        await oldHTTP.waitForGateRegistration()
        try await client.attach(endpoint: endpoint(host: "new.local"))
        oldHTTP.releaseGates()

        await XCTAssertRouterRuleThrowsError(try await read.value) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(oldHTTP.calls.count, 1)
    }

    func testQueuedReadWaitsForMutationAndItsAuthoritativeRelist() async throws {
        let f = try await fixture([
            ScriptedRouterHTTPClient.ok(lowBatteryJSON),
            ScriptedRouterHTTPClient.ok("[\(lowBatteryJSON)]"),
            ScriptedRouterHTTPClient.ok("[\(lowBatteryJSON)]"),
        ], gateRequests: true)
        let rule = try known(lowBatteryJSON)

        let mutation = Task { try await f.client.createRule(rule) }
        await f.http.waitForCallCount(1)
        let queuedRead = Task { try await f.client.rules() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.http.calls.map(\.method), ["POST"])

        f.http.releaseNextGate()
        await f.http.waitForCallCount(2)
        XCTAssertEqual(f.http.calls.map(\.method), ["POST", "GET"])
        f.http.releaseNextGate()
        _ = try await mutation.value

        await f.http.waitForCallCount(3)
        XCTAssertEqual(f.http.calls.map(\.method), ["POST", "GET", "GET"])
        f.http.releaseNextGate()
        _ = try await queuedRead.value
    }

    func testQueuedMutationFromReplacedAttachmentNeverDispatches() async throws {
        let oldHTTP = ScriptedRouterHTTPClient(
            results: [ScriptedRouterHTTPClient.ok("[]")],
            gateRequests: true
        )
        let oldEndpoint = endpoint(host: "old.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("client-token", for: oldEndpoint, role: .client)
        try await credentials.saveToken("admin-token", for: oldEndpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { _ in oldHTTP }
        try await client.attach(endpoint: oldEndpoint)
        let rule = try known(lowBatteryJSON)

        let read = Task { try await client.rules() }
        await oldHTTP.waitForCallCount(1)
        let mutation = Task { try await client.createRule(rule) }
        for _ in 0..<20 { await Task.yield() }
        try await client.attach(endpoint: endpoint(host: "new.local"))
        oldHTTP.releaseNextGate()

        await XCTAssertRouterRuleThrowsError(try await read.value) {
            XCTAssertTrue($0 is CancellationError)
        }
        await XCTAssertRouterRuleThrowsError(try await mutation.value) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(oldHTTP.calls.map(\.method), ["GET"])
    }

    func testMutationSuccessWithRelistFailureSurfacesFailureWithoutGuessedState() async throws {
        let f = try await fixture([
            ScriptedRouterHTTPClient.ok(lowBatteryJSON),
            .failure(NetworkError.timeout),
        ])
        await XCTAssertRouterRuleThrowsError(
            try await f.client.createRule(known(lowBatteryJSON))
        ) {
            XCTAssertEqual($0 as? NetworkError, .timeout)
        }
        XCTAssertEqual(f.http.calls.map(\.method), ["POST", "GET"])
    }

    func testCompatiblePresetUpdatePreservesEveryOtherFieldAndWebhook() throws {
        let source = try known(#"{"name":"no_input_shutdown","enabled":true,"condition":"input_power","state":"absent","hold":600000000000,"hysteresis_margin":9,"repeat_every":30000000000,"actions":["shutdown","webhook:https://example.test/lost"],"confirm_shutdown":true}"#)
        let preset = RouterPowerLossPreset(document: .known(source))
        XCTAssertTrue(preset.isCompatible)
        let changed = try preset.updating(enabled: false, hold: .init(nanoseconds: 120_000_000_000), confirmShutdown: true)
        XCTAssertEqual(changed.hysteresisMargin, 9)
        XCTAssertEqual(changed.repeatEvery, source.repeatEvery)
        XCTAssertEqual(changed.actions, source.actions)
    }

    func testIncompatiblePresetRequiresExplicitResetAndResetIsCanonical() throws {
        let source = try known(#"{"name":"no_input_shutdown","enabled":true,"condition":"battery_level","op":"below","percent":5,"hold":0,"hysteresis_margin":5,"actions":["shutdown"],"confirm_shutdown":true}"#)
        let preset = RouterPowerLossPreset(document: .known(source))
        XCTAssertFalse(preset.isCompatible)
        XCTAssertThrowsError(try preset.updating(enabled: true, hold: .init(nanoseconds: 1), confirmShutdown: true))
        XCTAssertThrowsError(try preset.reset(enabled: true, hold: .init(nanoseconds: 1), confirmed: false))
        let reset = try preset.reset(enabled: true, hold: .init(nanoseconds: 600_000_000_000), confirmed: true)
        XCTAssertEqual(reset.name, RouterPowerLossPreset.reservedName)
        XCTAssertEqual(reset.condition, .inputPower(state: .absent))
        XCTAssertEqual(try reset.hold.nanoseconds(), 600_000_000_000)
        XCTAssertEqual(reset.hysteresisMargin, 5)
        XCTAssertNil(reset.repeatEvery)
        XCTAssertEqual(reset.actions, [.shutdown])
        XCTAssertTrue(reset.confirmShutdown)
    }

    private func fixture(
        _ results: [Result<(Data, HTTPURLResponse), Error>],
        gateRequests: Bool = false
    ) async throws -> (client: RouterAdministrationClient, http: ScriptedRouterHTTPClient) {
        let http = ScriptedRouterHTTPClient(results: results, gateRequests: gateRequests)
        let endpoint = endpoint(host: "router.local")
        let credentials = RouterCredentialStore(backend: AdministrationCredentialBackend())
        try await credentials.saveToken("client-token", for: endpoint, role: .client)
        try await credentials.saveToken("admin-token", for: endpoint, role: .administrator)
        let client = RouterAdministrationClient(credentials: credentials) { _ in http }
        try await client.attach(endpoint: endpoint)
        return (client, http)
    }

    private func endpoint(host: String) -> RouterEndpoint {
        RouterEndpoint(
            scheme: "https",
            host: host,
            port: 8378,
            certificateFingerprint: String(repeating: "01", count: 32),
            allowsInsecureWAN: false
        )
    }

    private func known(_ json: String) throws -> RouterRule {
        let document = try JSONDecoder().decode(
            RouterRuleDocument.self,
            from: Data(json.utf8)
        )
        guard case let .known(rule) = document else {
            throw RouterRuleValidationError.invalidRule
        }
        return rule
    }
}

private let lowBatteryJSON = #"{"name":"low_battery","enabled":true,"condition":"battery_level","op":"below","percent":15,"hold":600000000000,"hysteresis_margin":5,"actions":["dc_off"],"confirm_shutdown":false}"#

private func XCTAssertRouterRuleThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
