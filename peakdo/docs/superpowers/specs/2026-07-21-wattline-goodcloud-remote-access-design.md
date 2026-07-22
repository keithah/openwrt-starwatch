# Wattline GoodCloud Remote Access Design

**Date:** 2026-07-21  
**Status:** Approved for implementation planning  
**Base:** `codex/wattline-phase-2` at `ec8425f2`

## Goal

Let the iOS and macOS Wattline apps reach the existing `wattlined` HTTP API on port `8377` when the router is off-LAN, using GL.iNet GoodCloud's rtty relay. LAN/Bonjour remains the preferred route, BLE remains unchanged, and all existing Wattline models, rules, settings, decoding, and bearer-token semantics continue to operate above the transport boundary.

## Scope and constraints

- Extend GoodCloudKit first, test-first, on a pushed feature branch. Wattline pins the resulting exact commit rather than a mutable branch head.
- Add general relay requests with caller-controlled method, path, headers, and body, plus convenience `get`, `post`, `put`, and `delete` methods.
- Add a streaming relay API so Wattline's full SSE telemetry works remotely.
- Preserve caller headers and body bytes verbatim. In particular, Wattline's `Authorization: Bearer <token>` is independent of GoodCloud authentication and must reach `wattlined` unchanged.
- Keep GoodCloud FE tokens in GoodCloudKit's Keychain storage and Wattline bearer tokens in Wattline's existing Keychain storage. Do not log passwords, tokens, cookies, authorization headers, request bodies, or unredacted GoodCloud server messages.
- Do not change `wattlined`, its API contract, BLE behavior, the one-BLE-owner invariant, or the existing LAN/Bonjour implementations.
- Support both Wattline iOS and macOS apps.
- Use only stubbed unit/integration transports until replacement router hardware is available.

## Existing architecture

Phase 2 exposes two relevant seams in `WattlineNetwork`:

- `RouterHTTPClient` supplies bearer-authenticated REST requests to `RouterTransport` and `RouterAdministrationClient`.
- `RouterEventStream` supplies SSE data frames to `RouterConnection`.

Production currently constructs `HTTPClient` and `SSEClient` over the same direct LAN `URLSession`. `RouterTransport`, administration clients, DTOs, and app models already depend on those protocols rather than concrete LAN clients. Remote support therefore belongs behind these two seams.

The actual daemon routes are under `/api/v1`; the hardware validation path is `/api/v1/status`, not bare `/status`.

## Chosen architecture

### GoodCloudKit relay surface

`RelayHTTPClient` will centralize relay URL construction, cookie installation, redirect policy, caller request fields, and relay-expiry recognition.

The ordinary request API is:

```swift
public func request(
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil
) async throws -> (Data, HTTPURLResponse)
```

Convenience methods delegate to it without changing caller values:

```swift
public func get(_ path: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse)
public func post(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse)
public func put(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse)
public func delete(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse)
```

The streaming API emits the response before body chunks so callers can validate status without buffering an unbounded stream:

```swift
public enum RelayHTTPStreamEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

public func stream(
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data? = nil
) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error>
```

Both paths install `gl-rtty-token` and `FE_TOKEN` in the supplied URLSession's cookie store, allow only GoodCloud-domain redirects, and stop before redirects emitted by the proxied target. Leading and non-leading slashes are normalized so Wattline's existing `/api/v1/...` paths append correctly to the encoded rtty target.

A final `404`/relay error page or redirect to `gl-rtty/error.html` maps to `GoodCloudError.sessionExpired`. Network failures remain `GoodCloudError.transport`; GoodCloud account API code `-1010` remains distinguishable as account-session expiry.

### Wattline remote session coordinator

`GoodCloudRelayCoordinator` is an actor in `WattlineNetwork`. It owns the signed GoodCloud API client abstraction, selected GoodCloud device ID, target port `8377`, and at most one in-flight or current `RemoteAccessSession` for a connection batch.

The coordinator:

1. Coalesces concurrent provisioning so initial REST and SSE setup do not create competing relay sessions.
2. Provisions a fresh session when a remote connection batch begins or no current session exists.
3. Invalidates the session on typed relay expiry.
4. Reprovisions and retries a GET, initial connection request, or SSE open once after relay expiry. A mutating POST, PUT, or DELETE is never replayed automatically because the client cannot prove whether `wattlined` applied it before the relay failed.
5. Never loops on GoodCloud `-1010`; it publishes account expiry and requires a new login.
6. Does not interpret `wattlined` `401`, `403`, decoding errors, or API errors as relay failures.

`RemoteRouterHTTPClient` conforms to `RouterHTTPClient`. It converts the existing token argument to the `Authorization` header, preserves the JSON content type and body used by current callers, and delegates through the coordinator.

`RemoteRouterEventStream` conforms to `RouterEventStream`. It opens `/api/v1/events` with `Accept: text/event-stream` through the streaming relay API and feeds chunks through the existing SSE frame parser. Cancellation terminates the underlying relay task. A stream reconnect begins a new route-selection batch.

### LAN-first route selection

`PreferredRouterRoute` shares route state between a preferred HTTP adapter and event-stream adapter.

- At connection start, the canonical status request tries the existing LAN client first.
- Only reachability/transport failures allow remote fallback.
- Cancellation, TLS pin failures, Wattline authentication failures, HTTP/API errors, and decoding failures remain authoritative and do not silently fall back.
- Once remote is selected, the connection batch shares its provisioned relay session for REST and SSE.
- Every subsequent SSE reconnect reevaluates LAN first, allowing the app to return naturally to Bonjour/LAN without disrupting a healthy remote stream.
- A successful LAN route never invokes GoodCloud.

This selector wraps the existing clients; it does not modify `HTTPClient`, `SSEClient`, Bonjour discovery, TLS validation, or `RouterTransport`.

Administration traffic uses the same preferred HTTP adapter, so rules, settings, history, and token administration do not bypass route policy.

## Account and device association

`GoodCloudAccountService` in `WattlineNetwork` encapsulates `GoodCloudAuth`, `PasswordTokenProvider`, and `SignedAPIClient`. It exposes redacted account states and app-facing device summaries without exposing FE tokens or relay cookies.

On launch it checks for a stored token and validates it by loading devices. A stale token is cleared silently for the initial logged-out screen. During active use, API `-1010` clears the GoodCloud session and surfaces a single reauthentication-required state.

`GoodCloudAssociationStore` persists only non-secret metadata in UserDefaults:

- saved Wattline router-host UUID;
- normalized Wattline router MAC/device identity;
- GoodCloud numeric device ID;
- last-known GoodCloud name, MAC, DDNS, model, and online state for presentation.

The device picker suggests an exact normalized-MAC match between the saved Wattline router and `GoodCloudDevice.mac`. Name and DDNS may help the user identify a router but never create an automatic association. The user explicitly confirms the selection. Offline devices remain visible but cannot be selected for immediate verification. Removing or changing the association never changes LAN enrollment or deletes Wattline bearer credentials.

## UI

Both iOS Settings and the macOS router administration/settings surface gain a Remote Access section.

Logged out:

- “Sign in to GoodCloud” opens an email/password sheet based on the GoodCloud Tester sample.
- Password entry uses `SecureField`; submit is disabled for empty fields and while a request is active.
- Password state is cleared after submission, dismissal, backgrounding, or logout.
- Errors are rendered from redacted, fixed app copy.

Logged in:

- Show account/session status and the associated GoodCloud router.
- Offer device selection, association removal/change, and logout.
- The picker shows name, model, normalized MAC, DDNS, and online/offline state, with an exact-MAC “Suggested” marker.

Connection presentation may report Local or Remote as status. Route selection remains automatic; a persistent “force remote” switch is out of scope.

Shared model/service code lives in `WattlineShared`/`WattlineNetwork`; platform views remain small adapters. Neither app imports or constructs a second BLE owner.

## Error and retry policy

| Condition | Behavior |
|---|---|
| LAN reachability failure | Fall back to associated, authenticated GoodCloud remote route. |
| LAN cancellation, TLS, auth, API, or decode failure | Surface existing error; do not fall back. |
| No GoodCloud login or no device association | Surface remote-unavailable guidance; LAN remains usable. |
| GoodCloud device offline | Surface device-offline guidance; do not retry continuously. |
| GoodCloud API `-1010` | Clear GoodCloud auth, stop remote stream, request login. |
| Relay session expired during GET/connect/SSE open | Invalidate, reprovision, and retry once. |
| Relay session expires during a mutation | Invalidate and surface an indeterminate transport failure; do not replay the mutation. |
| Second relay expiry/failure | Surface remote transport failure and let existing reconnect policy schedule the next batch. |
| wattlined `401/403` | Preserve existing Wattline credential handling; never request GoodCloud login. |
| SSE interruption | Mark telemetry stale through existing connection behavior; next reconnect tries LAN first, then remote. |

Errors crossing into Wattline use fixed categories and redacted descriptions. No error may embed request headers, body data, URLs containing relay target details, server response bodies, or credentials.

## Testing strategy

All production changes follow a witnessed red-green-refactor cycle.

### GoodCloudKit

StubURLProtocol tests prove:

- GET, POST, PUT, DELETE, and arbitrary methods are preserved;
- paths with or without a leading slash produce the correct encoded relay target;
- caller `Authorization`, `Accept`, and `Content-Type` headers are present unchanged;
- body bytes are present unchanged;
- relay cookies are installed for `.goodcloud.xyz` and survive the ssh-to-web host redirect;
- proxied target redirects are not followed;
- response and incremental data events are delivered in order without waiting for EOF;
- cancellation cancels the URLSession task;
- relay expiry maps to `GoodCloudError.sessionExpired`;
- token/cookie values never appear in textual descriptions.

### WattlineNetwork

Injected fakes prove:

- remote REST forwards method, canonical `/api/v1/...` path, Wattline bearer, content headers, and body;
- remote SSE provisions the associated GoodCloud device on port `8377` and emits parsed data frames;
- concurrent REST/SSE startup coalesces provisioning;
- relay expiry invalidates and reprovisions once;
- LAN success never invokes GoodCloud;
- LAN reachability failure selects remote;
- LAN TLS/auth/API/decode failures do not select remote;
- SSE reconnect reevaluates LAN first;
- GoodCloud `-1010` becomes reauthentication-required without exposing server text;
- no association/login produces a stable remote-unavailable error.

### Association and UI state

Unit and app-model tests prove:

- MAC normalization and exact-match suggestions;
- explicit selection and persistence round trips;
- removal leaves LAN host and bearer credentials intact;
- stored GoodCloud tokens are validated at launch;
- login, logout, loading, expired-session, device-list, selection, and redacted-error states;
- iOS and macOS production wiring includes the same account service without changing BLE factories.

Full baseline verification includes `swift test` for GoodCloudKit, WattlineCore, WattlineNetwork, and WattlineUI, plus iOS/macOS app builds and unit-test targets. The existing WattlineNetwork test-fixture Sendable warning is a known baseline warning and should not grow.

## Dependency and repository delivery

GoodCloudKit work is committed on `codex/relay-http-request-stream`, based on current `main` at `20690c9` (which contains the `v0.1.0` release), pushed to `https://github.com/keithah/goodcloudkit`, and verified independently. Wattline declares the public package URL but pins the exact GoodCloudKit commit revision containing the relay request and streaming additions.

Wattline work occurs on `codex/wattline-goodcloud`, created from committed `codex/wattline-phase-2` HEAD. Existing uncommitted changes in the Phase-2 worktree are not included or modified. The specification is committed before the implementation plan; implementation follows the committed plan through subagent-driven development and per-task review.

## Deferred live validation

No compatible Wattline router is currently available because the GL-X3000 is out for RMA. Unit tests can prove that the native client constructs and transmits headers/body through its relay request, but they cannot prove GL.iNet's deployed relay forwards those fields to the target.

When replacement hardware arrives:

1. Log in through Wattline and associate the X3000 GoodCloud device.
2. Provision `remoteAccess(deviceID: ..., port: 8377)`.
3. Request `/api/v1/status` with the stored Wattline bearer token and confirm a `200` Wattline JSON response.
4. Exercise a JSON mutation and confirm `wattlined` receives the authorization header and exact body.
5. Hold `/api/v1/events` open and confirm live SSE frames arrive through the relay.
6. Move between LAN and off-LAN networks and confirm LAN preference, remote fallback, and return to LAN on reconnect.
7. Log into GoodCloud elsewhere and confirm `-1010` returns Wattline to its GoodCloud login surface without affecting LAN/BLE credentials.

This live checklist is the final confirmation that the deployed rtty relay preserves request headers, bodies, and streaming behavior end-to-end.

## Out of scope

- Changes to `wattlined`, its routes, or its authentication model.
- BLE changes or a second BLE transport owner.
- VPN, port-forwarding, or a Wattline-operated cloud proxy.
- Background always-on remote monitoring beyond existing app lifecycle behavior.
- A force-remote mode.
- GoodCloud social/OIDC login; this release uses the verified email/password flow already implemented by GoodCloudKit.
