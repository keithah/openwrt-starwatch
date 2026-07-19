# Code Review Hardening Design

## Goal

Resolve the July 2026 daemon, packaging, networking, alerting, history, and dashboard review findings without changing public JSON field names, weakening WebSocket same-origin checks, adding an HTTP write timeout, or expanding Starwatch's control scope.

## Delivery shape

Work proceeds on `fix/code-review-hardening` in review-priority order. Each behavioral change starts with a regression test that fails for the reported reason, receives the smallest implementation needed to pass, and is followed by `go build ./...`, `go vet ./...`, and `go test ./...` from `router/`. Closely related findings may share a commit, but unrelated refactors are excluded.

The existing intermittently failing `TestWebSocketDisconnectsWhenBoundedEventBufferOverflows` is part of the baseline stabilization work. It will be made condition-driven rather than timing-dependent before relying on the full suite as a gate.

## JSON and HTTP boundaries

All API and WebSocket values pass through one type-preserving finite-number sanitizer immediately before encoding. It recursively clones values, turns non-finite float pointers into `nil`, and replaces non-finite scalar or slice floats with zero where the existing Go type cannot represent JSON `null`. Types with their own JSON marshaler, notably `time.Time`, remain intact. HTTP responses are marshaled before headers are committed, preventing truncated `200` responses. WebSocket values are sanitized before the injectable writer is called, so both production and test writers receive JSON-safe data.

Query-string tokens are accepted only by `/api/ws`; all other API routes require `Authorization: Bearer`. The coder/websocket origin policy remains unchanged. The HTTP server gains an idle timeout while retaining its header timeout. Read and write timeouts remain zero because their connection deadlines can survive HTTP hijacking and terminate long-lived WebSockets.

## Storage durability and history correctness

SQLite uses WAL, `synchronous=FULL`, and a five-second `busy_timeout`. WAL supplies an on-disk recovery journal while FULL preserves the project's conservative power-loss posture. Existing quick-check and corrupt-database recovery remain in place.

UCI writes sync the temporary file before close, rename it atomically, and sync the parent directory after rename. UCI parsing decodes the writer's apostrophe escape and rejects newline-bearing endpoint updates. Rule fields that have no persisted UCI option are rejected rather than accepted transiently. Configuration callbacks run after releasing the manager lock.

The tiered reader obtains its minute/quarter boundary from the SQLite store's configured minute retention. Pre-NTP pending queues are bounded, and RAM queries discard zero timestamps and sort an out-of-order snapshot before binary search. Fixed `parseSpan` values already eliminate the reviewed arbitrary-day overflow path; tests preserve that invariant. Obstruction PNG rendering moves to an in-memory buffer so encode failures occur before content type or status is committed.

## Alert lifecycle and delivery

Disabling an active rule emits a resolved notification before removing state. Alert runtime state is stored in a dedicated SQLite table through a narrow engine state-store interface. The persisted document contains active rule timing/detail plus failover readiness and its last set. The engine restores this state at construction, updates it after transitions, and deletes resolved/disabled rule state, preventing duplicate firing and missed resolves across normal restarts.

Webhook and ntfy delivery use independent bounded worker queues. The central dispatcher fans out without waiting for either endpoint, so retries at one destination cannot block queue drain or the other destination. Webhook retries are limited to network failures, HTTP 429, and HTTP 5xx responses; other 4xx responses are terminal. Logs identify the alert and endpoint kind but only include sanitized error text that cannot contain configured URLs or credentials.

## Networking and dish behavior

MWAN refresh retains the last-good status when both current probes fail. A dedicated apply mutex serializes assist/apply transactions, and successful UCI changes use `mwan3 reload` rather than a full restart.

The raw ICMP prober resolves DNS names before constructing `net.IPAddr`; failure to resolve reports ICMP unavailable so the existing UDP fallback runs. Speedtest status polls receive a per-RPC timeout. Only gRPC `Unimplemented` contributes to the unsupported threshold; `Unavailable` remains a transient retryable failure. Alignment uses boresight azimuth/elevation from `AlignmentStats` whenever that message is present.

## Packaging and access control

The public feed is already signed in CI through the existing `signed-feed-artifact` target and pinned installer key. Local feed generation gains optional `SIGN_KEY` support: when set and `usign` is available it emits `Packages.sig`; when unset it deliberately produces the existing unsigned development artifact and documentation states that only signed HTTPS/release-checksummed artifacts are installable trust anchors.

The LuCI token RPC moves from read ACL scope to write scope; the GL/OUI equivalent is inspected and changed only if it exposes the same read permission. The default `0.0.0.0` listener remains because OpenWrt LAN addresses are dynamic, but its shipped comment and documentation explicitly state that firewall policy controls exposure.

## Dashboard behavior

The live client returns immediately after a WebSocket 1008 unauthorized close, without starting polling or scheduling reconnect. Successful empty or non-JSON 2xx responses resolve to `null`. Settings normalize missing config sections and probe-host arrays, and cleared numeric fields remain unset instead of becoming zero. Repeated render nodes receive stable keys. History assembly preserves `null` as a graph gap instead of coercing it to zero. The existing browser logic harness receives regression assertions for each pure behavior, while Go static-serving coverage confirms the edited assets remain embedded.

## Already-correct review items

Two cited findings describe code that no longer exists on the reviewed `main` tip:

- Production opkg publication already creates and verifies `Packages.sig`; this work adds only the requested optional local signing path and supporting documentation/tests.
- `parseSpan` is a fixed lookup over `15m`, `3h`, `24h`, `7d`, and `30d`; there is no numeric-day multiplication that can overflow.
These paths are verified by tests rather than rewritten.

## Verification

Every red/green cycle is followed by the required module build, vet, and test commands. Final verification additionally runs race tests, package tests/feed generation, the browser pure-logic harness, and an ARM64 static build. No live dish, client, Wi-Fi, radio, routing, or firewall mutation is part of verification.
