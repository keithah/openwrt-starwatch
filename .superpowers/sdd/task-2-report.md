# Task 2 report

Implemented injected router HTTP/SSE protocols, URLSession-backed clients, and deterministic FakeRouterServer.

## RED

Command before implementation:

```text
swift test --package-path peakdo/apple/WattlineNetwork --filter HTTPAndSSEClientTests
```

Expected failure: focused client/fixture types and tests were absent.

## GREEN

```text
swift test --package-path peakdo/apple/WattlineNetwork --filter HTTPAndSSEClientTests
```

Result: 4 tests passed, 0 failures. Tests cover bearer authorization, JSON response, SSE data framing and blank lines, malformed frame rejection, and stream closure. Fixture requests are local-only (`fake.local`); no external network requests occur.

Commit: `b097905d test: add router HTTP and SSE fixture`

## Review-fix RED/GREEN evidence

The prior fake-only tests were replaced with URLProtocol-backed tests that invoke `HTTPClient` and `SSEClient` directly. `FakeRouterServer.pushFrame` now forwards raw wire bytes and does not invoke `SSEFrameParser`.

### RED (before review fix)

Command:

```text
swift test --package-path WattlineNetwork --filter HTTPAndSSEClientTests
```

Result: 6 tests executed, 2 failures. `testHTTPClientRejectsInvalidURL` did not throw, and `testSSEClientParsesRawDataFramesAndBlankLines` received one combined 20-byte event because the URLProtocol response was delivered as a single chunk to `bytes.lines`.

### GREEN (after review fix)

Command:

```text
swift test --package-path WattlineNetwork --filter HTTPAndSSEClientTests
```

Result: 6 tests executed, 0 failures. The suite drives local URLProtocol responses through real clients and covers bearer headers, JSON decoding, non-2xx `NetworkError`, invalid URL, raw SSE data frames/blank lines, malformed frames, and clean stream closure.

Exact GREEN output:

```text
Executed 6 tests, with 0 failures
Test Suite 'Selected tests' passed
```

## Streaming re-review fix RED/GREEN evidence

### RED (buffered `data(for:)` implementation)

Command:

```text
swift test --filter HTTPAndSSEClientTests/testSSEClientYieldsFramesBeforeConnectionFinishes
```

Exact output:

```text
XCTAssertFalse failed (2 assertions)
Test Case 'testSSEClientYieldsFramesBeforeConnectionFinishes' failed
Executed 1 test, with 1 failure
```

### GREEN (streaming `bytes(for:)` implementation)

Command:

```text
swift test
```

Exact output:

```text
Executed 11 tests, with 0 failures
Test Suite 'All tests' passed
```

The URLProtocol fixture now delivers two SSE chunks before delayed completion; the test asserts both events arrive while `didFinishLoading` remains false. SSE invalid-path and non-2xx tests are also covered.
