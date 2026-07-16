# Starwatch for OpenWrt

Starwatch is an offline-first Starlink observatory for OpenWrt and GL.iNet
routers. A static Go daemon reads the dish's local gRPC API, combines dish and
router-side WAN telemetry, keeps tiered history, evaluates alerts, exposes a
token-authenticated REST/WebSocket API, and serves a responsive embedded
dashboard. No cloud account or Internet connection is required.

The dashboard is available directly on port 9633, from **Services →
Starwatch** in LuCI, or from **Applications → Starwatch** in the GL.iNet panel.
The admin-panel packages pass the generated token to the dashboard through a
small authenticated RPC bridge, so the router login remains the access
boundary.

> Screenshot placeholder: add the GL.iNet dashboard capture after the §13.4
> on-device verification pass.

## Build the packages

The packages use the same no-SDK pipeline verified by Wattline on a GL-X3000:
a plain static Go cross-compile and hand-rolled OpenWrt packages.

```sh
make -C package all
ls -la package/out/*.ipk
```

The build produces:

- `starwatchd_1.0.0_aarch64_cortex-a53.ipk` — static daemon, embedded SPA,
  UCI configuration, guarded dish route, token generator, and procd service.
- `luci-app-starwatch_1.0.0_all.ipk` — LuCI menu, one-method rpcd bridge, and
  iframe launcher.
- `gl-app-starwatch_1.0.0_all.ipk` — GL.iNet oui menu, Lua RPC bridge, and
  evaluated Vue 2 iframe view.

The outer `.ipk` is a **gzipped ustar tar**, not an `ar` archive. Its three
members are `debian-binary`, `control.tar.gz`, and `data.tar.gz`. This exact
format matters: the GL-X3000 opkg build segfaults on the ar form and rejects
macOS pax headers. All payload paths remain below ustar's 100-character limit.

`ARCH` defaults to `aarch64_cortex-a53`. Override the version or filename
architecture when needed:

```sh
make -C package VERSION=1.0.1 ARCH=aarch64_cortex-a53 all
```

The committed GL view at
`package/gl-app-starwatch/www/views/gl-sdk4-ui-starwatch.common.js` was produced
as the returning Vue 2 IIFE consumed by GL's `eval(res.data)` loader, following
the live-verified Wattline bundle contract. `package/Makefile` creates the
`.js.gz` artifact installed under `/www/views`; no npm or frontend build step is
required.

When iterating, remember that `opkg install` skips a same-version reinstall.
Use `opkg install --force-reinstall`, or preferably bump `VERSION`, so the
control metadata, filename, and feed index advance together.

## Development install over SSH

OpenWrt dropbear often lacks scp support, so pipe each package over SSH:

```sh
for f in package/out/*.ipk; do
  ssh root@192.168.8.1 "cat > /tmp/$(basename "$f")" < "$f"
done

ssh root@192.168.8.1 'opkg update && opkg install \
  /tmp/starwatchd_1.0.0_aarch64_cortex-a53.ipk \
  /tmp/luci-app-starwatch_1.0.0_all.ipk \
  /tmp/gl-app-starwatch_1.0.0_all.ipk'
```

Install either admin-panel package or both. `starwatchd`'s post-install script
runs `/etc/uci-defaults/99-starwatch`, enables the service, and **restarts** it
so upgrades immediately use the new binary. The defaults script generates a
token when empty. It adds `network.starwatch_dish`, a `/32` route through the
logical `wan` interface, only when neither UCI nor the live kernel table already
contains a dish host route.

## Install and upgrade from an opkg feed

Build all packages plus `Packages` and `Packages.gz`:

```sh
make -C package VERSION=1.0.1 feed
# package/out/{*.ipk,Packages,Packages.gz}
```

Host `package/out/` on an HTTP server reachable by the router, then register it
once:

```sh
echo 'src/gz starwatch https://your-host/starwatch-feed' >> /etc/opkg/customfeeds.conf
opkg update
opkg install starwatchd luci-app-starwatch gl-app-starwatch
```

For later releases, bump `VERSION`, publish the refreshed feed, and run:

```sh
opkg update
opkg upgrade starwatchd luci-app-starwatch gl-app-starwatch
```

The GL.iNet Plug-ins page can use the same feed. mwan3 is optional; Starwatch
reports its status and offers an explicit failover-assist flow when installed.

## Configuration

`/etc/config/starwatch` is an opkg conffile, so local changes survive upgrades.
The safe subset is also editable from the dashboard.

```uci
config starwatch 'main'
    option listen '0.0.0.0'
    option port '9633'
    option token ''
    option dish_addr '192.168.100.1:9200'
    option poll_status '1'
    option poll_map '900'
    option wan_iface ''
    option probe_hosts '1.1.1.1 8.8.8.8'
    option probe_interval '2'
    option location_enabled '0'

config history
    option ram_hours '3'
    option minute_days '7'
    option quarter_days '30'
    option db_path '/etc/starwatch/history.db'
    option flush_secs '300'

config alerts
    option webhook_url ''
    option ntfy_url ''
```

The shipped file documents every alert enable and threshold. The principal
thresholds are outage hold (30 seconds), unreachable hold (60 seconds), path
loss (20%), path RTT (300 ms), path clear hold (300 seconds), and daily
obstruction (2%). Changes to listen address, port, token, dish address, RAM
capacity, database path, or flush cadence require a service restart.

Useful service commands:

```sh
/etc/init.d/starwatch restart
/etc/init.d/starwatch reload
logread -e starwatchd
```

## API summary

All `/api/*` routes require `Authorization: Bearer <token>`; browser clients
may use `?token=` for WebSocket and bootstrap access. Read the generated token
with `uci get starwatch.main.token`.

| Endpoint | Purpose |
|---|---|
| `GET /api/status` | Dish, topology, availability, config readback, and router card |
| `GET /api/history?series=&span=` | RAM/minute/quarter telemetry history |
| `GET /api/wan` | Interface probes, rates, and optional mwan3 state |
| `GET /api/outages?span=` | Merged dish, reachability, and path outage timeline |
| `GET /api/events?span=` | Alert, control, configuration, and lifecycle audit log |
| `GET /api/obstruction-map` | Cached obstruction grid or PNG |
| `POST /api/control/<action>` | Audited dish controls |
| `GET`, `POST /api/speedtest` | Speed-test state and trigger |
| `GET`, `PUT /api/config` | Read or update safe daemon settings |
| `GET /api/ws` | One-hertz snapshots and asynchronous events |

The complete wire format and operational constraints are in
[`STARWATCH-SPEC.md`](STARWATCH-SPEC.md).
