# Security Policy

## Supported versions

Starwatch is pre-1.0. Security fixes are applied to the latest release only.

| Version | Supported |
|---|---|
| 0.1.x (latest) | ✅ |
| < 0.1.0 | ❌ |

Always run the newest release from the signed feed (see below).

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub's **[Report a vulnerability](https://github.com/keithah/openwrt-starwatch/security/advisories/new)**
(Security → Advisories), or by email to **keith@kodi.tv** with `SECURITY` in the
subject.

Please include:

- affected version and router model / firmware (e.g. GL-X3000, GL 4.x),
- a description of the issue and its impact,
- reproduction steps or a proof of concept,
- any relevant logs (redact tokens and Wi-Fi passphrases).

What to expect:

- acknowledgement within **3 business days**,
- an assessment and remediation plan, kept in private coordination with you,
- a fixed release and a credited advisory on coordinated disclosure (we aim for
  90 days or sooner).

## Scope

In scope: the `starwatchd` daemon, its HTTP/WebSocket API, the LuCI and GL.iNet
panel apps, the `install.sh` bootstrap, and the signed opkg feed.

Out of scope: the upstream Starlink dish/router firmware and its gRPC API,
OpenWrt/GL.iNet firmware itself, and third-party dependencies (report those to
their maintainers). Vendored protobufs under `router/third_party/` carry their
own upstream license and are out of scope here.

## Feed and package integrity

The opkg feed index is signed with a dedicated Starwatch `usign` key. The
installer pins the public key alongside OpenWrt's existing keys and leaves
global signature checking enabled, so `opkg` verifies every package list.

- Public key fingerprint: **`f6c72c675c844b91`**
- Public key: [`package/starwatch-feed.pub`](package/starwatch-feed.pub)

The signing private key is held only as a GitHub Actions secret and is never
committed. If you believe the feed or key has been compromised, report it
privately as above — do not install until it is confirmed clean.

## Design notes relevant to security

- **Local-first, no cloud.** The daemon talks to the local dish/router gRPC and
  the LAN only; it uses no Starlink account and sends no telemetry off-router.
  The one network fetch outside the LAN is the installer downloading packages
  from the signed feed.
- **Token-gated API.** Every `/api/*` route requires the bearer token from
  `uci get starwatch.main.token`. An empty token denies all requests. The LuCI
  and GL.iNet launchers pass the token through their authenticated admin
  sessions, so the router login remains the access boundary. Prefer not exposing
  port 9633 to untrusted networks.
- **Guarded router writes.** Wi-Fi/client mutations require typed confirmations,
  a matching config revision, and upstream read-back confirmation. Wi-Fi
  passphrases are write-only — never returned, logged, audited, or echoed — and
  network edits refuse to proceed if they would erase another network's
  credentials.
- **Narrow routing scope.** The self-healing route manager only ever maintains
  the single `192.168.100.1/32` dish host route and never alters general
  routing or firewall configuration.
