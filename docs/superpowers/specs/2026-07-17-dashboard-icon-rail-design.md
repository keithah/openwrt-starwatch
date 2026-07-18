# Dashboard Icon-Rail Navigation Design

## Goal

Replace the dashboard’s single long card stack with seven hash-addressable sections behind a compact icon rail, while preserving the current local data, token, live WebSocket, and Preact/HTM architecture.

## Readers and outcome

This design is for a Starwatch operator. After reading it, they can reach any dashboard capability through a stable deep link, understand the live status at a glance, and personalize only the Overview without changing daemon configuration.

## Architecture

The SPA remains a static ES-module Preact application. `App` derives the active section from `location.hash`, retains the existing data hydration and live client, and renders a rail, sticky section header, and one section content grid. Existing cards are reused unchanged wherever possible; no API or daemon contract changes are required.

## Navigation

The rail has these destinations:

| Section | Hash | Content |
|---|---|---|
| Overview | `#/` | Live telemetry, WAN health, power, obstruction, alignment, alerts |
| Telemetry | `#/telemetry` | Full telemetry graph, obstruction, alignment |
| Connectivity | `#/connectivity` | WAN health and outage timeline |
| Power | `#/power` | Full power card and sleep controls |
| Controls | `#/controls` | Dish controls and speed test |
| Events | `#/events` | Alerts and audit-event list |
| Settings | `#/settings` | Existing settings view |

Desktop reserves a 74px sticky rail. Its absolutely positioned panel expands to 224px on hover without shifting content; rows use semantic links, visible focus, and native titles while collapsed. At sub-720px widths, the rail becomes a hamburger-triggered, focus-managed left drawer.

## Header and controls

The main column has a sticky header carrying the section eyebrow/title, the existing snapshot-derived online state and metric strip, plus controls. `LIVE` is derived from the existing connection state. `FULL` uses the Fullscreen API and tracks `fullscreenchange`. `CUSTOMIZE` opens the Overview-only right slideout.

The slideout traps keyboard focus, closes with Escape or backdrop click, restores focus to its trigger, and announces control errors through a live region.

## Personalization

Overview visibility persists as `starwatch.overview.cards`; compact density persists as `starwatch.density`. Only these six cards are configurable: live telemetry, WAN health, power, obstruction, alignment, and alerts. Hidden cards are not rendered and the responsive grid reflows. A missing-data card remains absent irrespective of its saved preference.

## Visual and responsive behavior

All added color uses existing `var(--*)` tokens so the existing light theme continues to apply. Desktop content is centered at 1200px with 16px grid gaps; normal content padding is 26px 24px and compact mode is 16px. The rail, drawers, toggle controls, and header adapt below 720px. The existing reduced-motion rule disables the new transition and animation effects.

## Testing and verification

The browser harness covers route selection, section card grouping, persisted Overview preferences, density reset, fullscreen state handling, and accessible drawer behavior. Existing static-asset serving tests must continue to prove the embedded daemon exposes the new assets. Go race tests, vet, and Linux ARM64 build remain release checks.

## Scope boundaries

This is a presentation-only change. It adds no dependencies, no bundler, no API or daemon changes, and does not modify the existing token or live-data transport.
