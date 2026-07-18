# Wattline Optional LAN/VPN Transport Implementation Plan

> **Superseded API tasks (2026-07-18):** This plan remains as milestone history,
> but its compatibility-route, TXT `fingerprint`, and pairing assumptions are no
> longer implementation guidance. The corrective execution plan is
> `2026-07-18-wattline-network-api-conformance.md`, based on the canonical router
> contract in `~/src/openwrt-wattline/docs/api.md`. Tasks completed under this
> older plan must be interpreted through that conformance plan; unsupported or
> deferred schedules, bypass threshold, OTA, rules, settings, token admin,
> BLE-device pairing, and expert controls are not app-advertised.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional bearer-authenticated LAN/VPN router transport while keeping Bluetooth primary, Demo available, and WattlineCore free of networking.

**Architecture:** A new `WattlineNetwork` SPM package owns URLSession, SSE parsing, NWBrowser, TLS policy, and Keychain seams. `RouterTransport` conforms to the existing `DeviceTransport`, maps the shipped `wattlined` HTTP/SSE API into Core events and commands, and uses telemetry for reconciliation. Thin iOS/macOS wiring presents manual router selection and deduplicates router/BLE identities without adding another BLE owner.

**Tech Stack:** Swift 6, Swift Package Manager, URLSession, Network.framework/NWBrowser, Security Keychain adapter, AsyncStream, XCTest, injected fake HTTP/SSE server.

## Global Constraints

- iOS deployment remains 17.0+ and macOS deployment remains 14.0+.
- `WattlineCore` and `WattlineUI` import no URLSession, Network, NetworkExtension, SwiftUI/UIKit/AppKit, WidgetKit, ActivityKit, AppIntents, UserNotifications, or ServiceManagement.
- `WattlineNetwork` is the only package allowed to import URLSession or Network.framework.
- No cloud relay, analytics, OTA, PIN/factory controls, or router-repository edits.
- Bluetooth remains primary; router selection is manual in this stream and automatic failover is deferred.
- Every mutation is telemetry-is-truth; no optimistic state. Preserve bypass telemetry reconciliation, Type-C mode semantics, power-limit SET→GET, and disconnect-as-success.
- Capability-gated surfaces are structurally absent, not disabled.
- Tokens are Keychain-backed and never logged or persisted as plaintext. Plain HTTP WAN requires explicit opt-in and warning.
- All tests use an in-process fake HTTP+SSE server; no real router or external network is required.

---

## Milestone 1 — Package boundary and protocol fixture

### Task 1: Add WattlineNetwork package and project dependency

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Package.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/NetworkError.swift`
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/PackageBoundaryTests.swift`
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`
- Modify: `peakdo/apple/Wattline/WattlineTests/...` only if package import coverage needs an app-target test

**Interfaces:**
- Produces library product `WattlineNetwork` depending on local `WattlineCore`.
- `NetworkError` cases: `.invalidURL`, `.unauthorized`, `.httpStatus(Int,String)`, `.decode(String)`, `.streamEnded`, `.unsupported(String)`, `.timeout`.

- [ ] Step 1: Write a failing import/dependency test asserting `WattlineNetwork` can construct `NetworkError.unauthorized` and that a source audit finds no networking imports in `WattlineCore`.
- [ ] Step 2: Run `swift test --package-path peakdo/apple/WattlineNetwork --filter PackageBoundaryTests`; expected failure because the package does not exist.
- [ ] Step 3: Add the package manifest, error type, and Xcode local package reference/product dependency; import only `Foundation` in the error model.
- [ ] Step 4: Run the focused test and `swift test --package-path peakdo/apple/WattlineCore`; both must pass.
- [ ] Step 5: Commit `feat: scaffold WattlineNetwork package`.

### Task 2: Build a deterministic fake HTTP+SSE server fixture

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/FakeRouterServer.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/HTTPClient.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/SSEClient.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/HTTPAndSSEClientTests.swift`

**Interfaces:**
- `protocol RouterHTTPClient: Sendable { func get(_ path: String, token: String) async throws -> (Data, HTTPURLResponse); func request(_ method: String, _ path: String, body: Data?, token: String) async throws -> (Data, HTTPURLResponse) }`.
- `protocol RouterEventStream: Sendable { func events(path: String, token: String) -> AsyncThrowingStream<Data, Error> }`.
- `FakeRouterServer` records method/path/body/authorization and lets tests push/close SSE frames.

- [ ] Step 1: Add tests for bearer header, JSON response decoding, SSE `data:` frame parsing, blank-line framing, malformed-frame rejection, and stream closure.
- [ ] Step 2: Run the focused tests; expected failures for missing client/fixture types.
- [ ] Step 3: Implement injected clients over `URLSession` plus the fake server seam. Do not add URLSession imports anywhere outside `WattlineNetwork`.
- [ ] Step 4: Run `swift test --package-path peakdo/apple/WattlineNetwork --filter HTTPAndSSEClientTests`; verify all requests are local fixture requests.
- [ ] Step 5: Commit `test: add router HTTP and SSE fixture`.

**Milestone 1 handoff:** Report package/Core/UI tests, import audit, and fixture test output. Stop for approval.

---

## Milestone 2 — RouterTransport and telemetry

### Task 3: Decode router identity and telemetry DTOs

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDTOs.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterMapping.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterMappingTests.swift`

**Interfaces:**
- `RouterIdentityDTO { model, hw_rev, firmware, mac, cid, features }`.
- `RouterSnapshotDTO { battery?, dc?, typec?, connected, updated_at }`.
- `RouterMapping.identity(_:) -> DeviceIdentitySnapshot` and `RouterMapping.events(snapshot:scope:observedAt:) -> [DeviceEvent]`.

- [ ] Step 1: Add vectors for status identity, full telemetry, missing ports, `connected=false`, signed charging/discharging status, and `updated_at`.
- [ ] Step 2: Run `RouterMappingTests`; expected failure before DTO/mapping implementation.
- [ ] Step 3: Implement Codable DTOs and lossless mapping. Missing objects stay absent; never synthesize zero-valued telemetry.
- [ ] Step 4: Run Core and Network tests; verify `DeviceTimestamp` conversion is explicit and deterministic.
- [ ] Step 5: Commit `feat: map router identity and telemetry`.

### Task 4: Implement RouterTransport connect, SSE reconnect, and stale quarantine

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTransport.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterConnection.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterTransportConnectionTests.swift`

**Interfaces:**
- `RouterEndpoint { scheme, host, port, certificateFingerprint, allowsInsecureWAN }`.
- `RouterTransport(endpoint:client:events:clock:backoff:)` conforms to `DeviceTransport`.
- `RouterTransport.connect(to:scope:)` emits handshake, connected, then telemetry events; stale stream generations are ignored.

- [ ] Step 1: Add failing tests for connect→`/status`→handshake, initial SSE telemetry, reconnect after stream drop, disconnected/stale emission, and old-generation frames being ignored after a new connect.
- [ ] Step 2: Run focused tests; expected failure because transport is absent.
- [ ] Step 3: Implement one connection actor with generation token, bounded reconnect backoff, authenticated status fetch, and SSE loop. `makeConnectionScope` uses a stable endpoint UUID and fresh session UUID.
- [ ] Step 4: Run focused tests, then Core and Network suites.
- [ ] Step 5: Commit `feat: add router transport telemetry stream`.

**Milestone 2 handoff:** Report executed Core and Network suites and reconnect/stale evidence. Stop for approval.

---

## Milestone 3 — Commands, capabilities, discovery, and credentials

### Task 5: Map commands with telemetry reconciliation

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterCommandMapper.swift`
- Modify: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterTransport.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterCommandTests.swift`

**Interfaces:**
- `RouterCommandMapper.route(for:) -> RouterRequest` where `RouterRequest` contains method, path, JSON body, and `reconcile: MutationReconciler`.
- `RouterTransport.perform(_:)` serializes requests and waits for matching authoritative SSE state or endpoint re-GET.

- [ ] Step 1: Add failing tests for DC on/off action, Type-C output action, limit set/clear with GET confirmation, bypass threshold, schedules, unsupported clock/shutdown, router errors, and disconnect-as-success.
- [ ] Step 2: Run focused tests; expected failures for route mapping/reconciliation.
- [ ] Step 3: Implement allow-listed endpoint mapping. For bypass, ignore HTTP result and wait for telemetry. For Type-C, reconcile from mode-derived state. For limits, SET then GET. Never report write acknowledgement as state confirmation.
- [ ] Step 4: Run focused tests and full Core/Network suites.
- [ ] Step 5: Commit `feat: map router commands with reconciliation`.

### Task 6: Add router capability gating and identity deduplication

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterCapabilities.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/DeviceIdentityDeduplicator.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/RouterCapabilitiesTests.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/DeviceIdentityDeduplicatorTests.swift`

**Interfaces:**
- `RouterCapabilities(features: UInt32, endpoints: Set<RouterEndpointCapability>)` exposes `supports(_:)`.
- `DeviceIdentityDeduplicator.merge(ble:router:) -> UnifiedDeviceRecord?` matches normalized MAC first, CID second, and marks Bluetooth preferred.

- [ ] Step 1: Add tests proving unsupported commands are absent, feature bits plus endpoint map gate surfaces, MAC case/format normalization, same-device merge, and distinct-device separation.
- [ ] Step 2: Run focused tests; expected failures.
- [ ] Step 3: Implement capability and dedup types without UI imports.
- [ ] Step 4: Run Core/UI/Network suites and source import audit.
- [ ] Step 5: Commit `feat: gate router capabilities and deduplicate devices`.

### Task 7: Add LAN discovery, remote host validation, and Keychain credential seam

**Files:**
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterDiscovery.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterHostStore.swift`
- Create: `peakdo/apple/WattlineNetwork/Sources/WattlineNetwork/RouterCredentials.swift`
- Test: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/DiscoveryAndCredentialsTests.swift`

**Interfaces:**
- `RouterDiscovery` wraps injected `NWBrowser` and parses `_wattline._tcp` TXT `id` and `fingerprint`.
- `RouterHostStore` validates LAN/VPN/HTTP(S) endpoints and persists only non-secret host metadata through an injected key-value store.
- `RouterCredentialStore` has async `readToken/saveToken/deleteToken`; production adapter uses Keychain, tests use an in-memory recorder.

- [ ] Step 1: Add failing tests for TXT parsing/deduplication, manual Tailscale host validation, invalid WAN HTTP without opt-in, fingerprint mismatch, token save/read/delete, and token redaction.
- [ ] Step 2: Run focused tests; expected failure.
- [ ] Step 3: Implement discovery and storage seams; keep Network.framework and Security imports confined to WattlineNetwork.
- [ ] Step 4: Run focused tests, all package suites, and forbidden-import audit.
- [ ] Step 5: Commit `feat: add router discovery and credentials`.

**Milestone 3 handoff:** Report command, capability, dedup, discovery, and credential test output. Stop for approval.

---

## Milestone 4 — App wiring, contract amendment, and verification

### Task 8: Amend privacy contract and add app transport selection

**Files:**
- Modify: `peakdo/Wattline-SPEC.md` §9 (the authorized contract amendment)
- Modify: `peakdo/apple/Wattline/Wattline.xcodeproj/project.pbxproj`
- Modify: `peakdo/apple/Wattline/Wattline/AppModel.swift`
- Modify: `peakdo/apple/Wattline/Wattline/Scan/...`
- Create: `peakdo/apple/Wattline/Wattline/RouterConnectionModel.swift`
- Test: `peakdo/apple/Wattline/WattlineTests/RouterAppWiringTests.swift`

**Interfaces:**
- `RouterConnectionModel` exposes discovered/manual endpoints, transport labels, DEMO/BT/Router selection, and saved-host actions.
- AppModel receives a `DeviceTransport` factory and keeps one owner per process; selecting RouterTransport never creates a BLE session.

- [x] Step 1: Add failing tests for router records alongside BLE records, manual host selection, same-device deduplication, unsupported surfaces absent from the view model, and no second transport owner.
- [x] Step 2: Run the app-target focused tests; expected failures.
- [x] Step 3: Wire the package into app targets, add Scan selection and “Connect via router” advanced path, and amend §9 to describe optional LAN/Tailscale/VPN token-authenticated no-cloud transport and insecure-WAN opt-in.
- [x] Step 4: Run focused app tests, Core/UI/Network suites, and generic iOS/macOS builds.
- [x] Step 5: Commit `feat: wire optional router transport into Wattline`.

### Task 9: Verification and handoff

**Files:**
- Modify: `peakdo/apple/WattlineNetwork/Tests/WattlineNetworkTests/NetworkAuditTests.swift`
- Modify: `peakdo/apple/docs/superpowers/plans/2026-07-17-wattline-network.md` only for checked results

- [x] Step 1: Run `swift test --package-path peakdo/apple/WattlineCore`.
- [x] Step 2: Run `swift test --package-path peakdo/apple/WattlineUI`.
- [x] Step 3: Run `swift test --package-path peakdo/apple/WattlineNetwork`.
- [x] Step 4: Run app tests/builds with `xcodebuild` for a generic iOS destination and macOS destination where available.
- [x] Step 5: Run audits: `rg` forbidden imports in Core/UI, `rg 'URLSession|NWBrowser|Network\.'` to confirm network isolation, `rg 'api\.peakdo\.ca|URLSession'` to ensure no OTA/cloud additions, and `git diff --check`.
- [x] Step 6: Document real-router, signed simulator, TLS fingerprint, and background reconnect checks that remain external.
- [x] Step 7: Commit `test: verify optional router transport boundaries` and stop for review.

**Milestone 4 handoff:** Deliver the complete diff, executed outputs, audit results, and external-check classification. Do not begin unrelated feature work without approval.

## Self-review checklist

- Router status/telemetry/SSE, actions, limits, bypass threshold, schedules, and pairing routes each have a task and non-vacuous tests.
- SSE reconnect, stale-generation quarantine, telemetry reconciliation, auth failures, capability gating, discovery, deduplication, Keychain, and insecure-WAN policy are covered.
- The plan explicitly preserves BLE primary, Demo mode, one BLE owner, Core/UI purity, deployment floors, and no cloud/OTA additions.
- The only contract edit is the authorized §9 privacy amendment; the router repository remains untouched.
