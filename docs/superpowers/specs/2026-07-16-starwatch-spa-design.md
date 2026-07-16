# Starwatch Task 6 SPA Design

## Outcome

Task 6 makes the existing Starwatch daemon API visible as a polished, fully offline dashboard while repairing the reviewed mwan3 failover-assist behavior. The final history contains two implementation commits: Part A for the mwan3 review fixes and Part B for the embedded SPA plus `POST /api/alerts/test`.

## Part A: mwan3 Assist Repair

`hasCustomConfig` will classify UCI sections structurally. It will ignore the singleton `globals` section and accept only the known pristine OpenWrt example sections for `wan`, `wanb`, their members, policy, and default rule. Any renamed section, changed option, extra non-Starwatch section, or unexpected value remains custom and disables the assist. This conservative allowlist keeps the §13.4 on-device-verification warning in place.

The proposed Starwatch changeset will create explicit primary and backup `interface` sections with `enabled=1`, `family=ipv4`, two `track_ip` values (`1.1.1.1`, `8.8.8.8`), and `reliability=1`, followed by the existing members, policy, and rule. When the pristine example default rule is present, the proposal will explicitly disable or replace it so it cannot compete with the Starwatch default rule. Tests use complete fresh-install and genuinely customized `uci show mwan3` fixtures and assert the exact structured changes.

## Delivery Architecture

The `web` directory is both a Go package and the static asset root. `web/embed.go` embeds the checked-in HTML, CSS, JavaScript modules, and vendored dependencies. It returns either the embedded filesystem or an `os.DirFS` rooted at `STARWATCH_WEB_DIR`, making development overrides a startup concern rather than a second server implementation.

The existing API server mounts this filesystem on its root route. Static routes are unauthenticated; existing `/api/*` patterns remain more specific and retain Bearer/query-token authentication. No frame-busting or `X-Frame-Options` header is added. `POST /api/alerts/test` is token-authenticated and accepts no settings mutation: it constructs an informational test notification and sends it through the same bounded dispatcher queue used by production alerts.

The browser uses direct ES modules with pinned, checked-in single-file ESM distributions of Preact, htm, and uPlot plus uPlot CSS. Runtime requests are relative and target only the daemon. There is no npm manifest, bundler, build command, CDN, analytics, or font request.

## Browser Modules

- `index.html` supplies metadata, the root mount, local styles, and the module entry point.
- `app.js` owns application state, hash routing, initial hydration, and top-level composition.
- `api.js` owns token bootstrap, authenticated fetches, 401 invalidation, WebSocket reconnect/backoff, and REST fallback polling.
- `logic.js` contains dependency-free state derivation, availability decisions, local/UTC minute conversion, model naming, and series alignment.
- `charts.js` is the only uPlot adapter. It creates, resizes, updates, and destroys live/history charts and supports min/max bands.
- `cards.js` contains focused dashboard card components and action flows.
- `views.js` contains the settings, events, and token-entry views.
- `test.html` runs browser assertions for the pure functions without a JavaScript toolchain.
- `styles.css` defines the complete responsive design system.

Modules communicate through plain objects and callbacks. Cards do not fetch independently except through passed action/load callbacks, preventing duplicate polling and token handling.

## Data Flow

On load, a `token` query parameter is copied to `sessionStorage`, removed with `history.replaceState`, and never written to persistent storage. With a token, the app concurrently loads status, initial graph history, WAN state, outages, recent events, speed-test state, and configuration data needed by visible views. The first status/history responses produce a useful initial paint before any WebSocket frame arrives.

The live client connects to the relative `/api/ws?token=...` URL. Status frames update the normalized dish/WAN state and append 1 Hz values to live 15-minute and 3-hour chart windows. Event frames refresh affected event/outage views. Disconnection starts exactly one two-second `/api/status` poller and exponential reconnect loop; successful WS connection stops polling.

Graph tab or span changes cancel stale loads and query the named series required for that view. The chart adapter aligns timestamps across series, labels dish-side and router-side rates distinctly, uses aggregate averages as the line, and renders min/max envelopes when supplied by persistent tiers. Longer spans remain REST-backed rather than accumulating browser history.

## Interface and Visual System

The dashboard keeps row-major DOM order at desktop widths. Graph cards span both columns above 1100 px; the layout becomes a single column below 720 px. The status shell remains mounted for `#/`, `#/settings`, and `#/events`.

The visual direction is a night-sky instrument panel rather than an admin console: near-black navy surfaces, cyan telemetry traces, restrained green/amber/red states, fine background grid texture, compact uppercase labels, tabular metric numerals, soft shadows, and subtle luminous borders. All colors are custom properties and receive a coordinated light-theme value through `prefers-color-scheme`. Motion is limited to meaningful state/connection transitions and respects reduced-motion preferences.

The fixed dashboard stack implements the requested status header and cards: live graphs, obstruction and polar canvas, merged outage timeline, alignment SVG, power, WAN/mwan3 assist, controls, speed test, alerts, hardware/Starlink-router data. Cards return no DOM when their data source is absent. A shared availability renderer emits an em dash and the daemon-provided reason tooltip for unavailable fields, never a fabricated zero.

Hash-routed settings expose only fields accepted by the existing safe config PUT contract. Alert delivery testing calls the new endpoint. Token regeneration requires confirmation, replaces the active session token, and presents the new value once with a copy action. The event route shows the audit stream with kind filters.

## Safety and Error Handling

Missing credentials or any 401 switches to the centered token-entry view. A valid token triggers hydration without reloading. Other failures stay scoped to their card, show concise retryable errors, and preserve the last honest data instead of replacing it with zeroes.

Dish-unreachable state disables every dish control with one explanatory banner while WAN-only information remains usable. Confirmation policy follows §5.1 exactly: typed reboot and failover confirmation, ordinary confirmation for stow/unstow, GPS, map clearing, and firmware update, and immediate application for snow melt and sleep schedule. Stow controls disappear on motorless hardware. Unsupported speed tests and unavailable failover assist display backend wording verbatim.

## Verification

Part A is test-first: fixtures demonstrate the current false refusal, then assert acceptance of pristine examples, rejection of customized config, tracked interface creation, and example-rule replacement.

Part B Go tests demonstrate static index and asset serving, `STARWATCH_WEB_DIR` replacement, iframe-safe response headers, unchanged API authentication, and normal alert dispatcher queueing. `test.html` covers state derivation, local/UTC minute conversion, availability decisions, and chart-series assembly by hand in a browser.

Before each requested implementation commit, run `go test -race ./...`, `go vet ./...`, and `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` from `starlink/openwrt/router`. Part B also builds a baseline and embedded binary for size comparison, launches the daemon on a development port with the dish absent, and curls `/` plus one vendored asset.

## Scope

This task does not add packaging, LuCI/GL integration, dish RPCs, WebSocket message shapes, or API shape changes beyond `POST /api/alerts/test`.
