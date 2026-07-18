# Starwatch Router, Dish Route, and Dashboard Design

## Scope

This change completes the read-only topology-B Starlink router model, makes the
dish management host route self-healing and resistant to VPN/default-route
hijacking, and adds local dashboard layout preferences. Router RPCs remain
read-only. Route mutation is limited to `192.168.100.1/32`; Starwatch never
changes a default route or firewall rule. Dashboard preferences remain browser
local and never enter daemon configuration.

## Router read model

The existing 60-second router poller remains the owner of reachability and the
status-card compatibility fields. RPC orchestration stays in `router.go`; pure
protobuf-to-local mappings and derived ping calculations live in a focused
mapper file. The poller reads status, history, clients, config, radio stats,
diagnostics, and network interfaces. Each result is cached through two
transient failures and becomes unavailable after the third.

`GET /api/router` reads only the typed local snapshot. It returns 503 outside
topology B or after the third router-status failure. Networks combine config
with diagnostics by domain. The nonexistent network and BSS IDs are omitted;
domain identifies a network, while SSID/band and an optionally empty BSSID
describe a BSS. Password strings never enter local models. Security is selected
only from the auth oneof. Radio configuration and statistics combine by band,
using real tx-power enum names and explicit HT/VHT-to-MHz mappings.

Router ping history is treated as a one-second circular buffer using `Current`.
Finite samples produce mean and population standard deviation. Five-minute
latency uses the newest 300 history samples; five-minute drop rate uses the
upstream status window. One-hour values require 3,600 samples and otherwise
carry field-specific unavailability. A success is a finite drop-rate sample
less than one. Every ping value is labeled derived.

## Self-healing dish route

`internal/dishroute` owns a small injectable command runner. It reads
`network.interface.wan`, preferring its physical `device`, reads that device's
IPv4 connected subnet, and accepts a configured nexthop only when it is inside
that subnet. Otherwise it accepts `192.168.1.1` only when `ip route get` proves
that address is directly reachable on the WAN device without `via`. A WAN with
no gateway receives a link-scope route. An off-subnet configured gateway with
no valid fallback is an error, not permission to write a misleading route.

The reconciler compares the existing exact host route before invoking `ip route
replace 192.168.100.1/32 ...`. It runs before initial dish discovery and before
every WAN-only discovery retry. Changes are logged and emitted as
`dish_route` events. `manage_dish_route=0` disables all route writes. The
first-boot shell script mirrors the same validation and preserves any existing
UCI or kernel route covering the dish.

## Dashboard customization

A dashboard manifest provides stable section and card IDs, labels, rail icons,
and card membership. Overview preferences contain only the visibility map and
compact-density setting; unknown IDs are dropped and data-driven card absence
remains authoritative over user visibility.

The header's Customize control opens an Overview-only right drawer. The rail
expands on desktop hover and becomes a hamburger-triggered left drawer on
mobile. Both drawers preserve focus, close with Escape, and respect the
existing dark/light variables and reduced-motion rules.

## Documentation and verification

API documentation removes nonexistent IDs and corrects derived/security/power
labels. The narrow host-route exception is documented in `STARWATCH-SPEC.md`.
The shipped UCI config documents the route gate. Tests use fake gRPC, fake
command output, and browser pure-logic assertions. Final gates are Go race,
vet, Linux/arm64 build, static asset serving, and `make -C package all`.
