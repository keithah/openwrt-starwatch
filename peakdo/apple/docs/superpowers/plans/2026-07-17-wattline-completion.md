# Wattline Non-OTA Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish Wattline's non-OTA roadmap with deterministic baseline tests, one-active-device discovery and switching, macOS surfaces, App Intents, Expert BLE controls, and release verification.

**Architecture:** Execute six independently reviewable plans in dependency order. The existing WattlineCore, WattlineNetwork, WattlineUI, DeviceOperationBroker, SnapshotCoordinator, and transport implementations remain authoritative; new app-only catalog code coordinates them without creating another BLE or HTTP owner.

**Tech Stack:** Swift 6, SwiftUI, CoreBluetooth, Network.framework, URLSession, Security/Keychain, WidgetKit, ActivityKit, AppIntents, ServiceManagement, XCTest, Xcode 26.

## Global Constraints

- iOS deployment target remains 17.0; macOS deployment target is 14.0.
- Bundle IDs remain `com.keithah.wattline`, `com.keithah.wattline.mac`, and platform-specific widget IDs; app group remains `group.com.keithah.wattline`.
- `WattlineCore` remains free of SwiftUI, UIKit, AppKit, ActivityKit, WidgetKit, AppIntents, UserNotifications, ServiceManagement, Network.framework, Security, and URLSession.
- URLSession, Network.framework, and Security remain confined to `WattlineNetwork`.
- One app model per process owns exactly one active `DeviceTransport` and `DeviceSession`; only that owner calls `connect()`.
- Telemetry or confirmed readback is authoritative. Preserve TYPE-C mode reconciliation, bypass's 10-second telemetry window, power-limit SET-then-GET, and expected-disconnect behavior.
- Capability- and route-gated UI is structurally absent, not disabled or opacity-hidden.
- Demo, Bluetooth, and Router routes use the same presentation and operation paths; Demo is visibly labeled.
- Charging is green, discharging is orange, idle is neutral, and numerals use monospaced digits on every surface.
- Do not add OTA/CDN/programming/recovery, Timers/schedules UI or codec, simultaneous multi-device connections, automatic transport failover, analytics, cloud services, or undocumented protocol commands.
- Never edit `peakdo/API.md`, `peakdo/src/*`, `scan.py`, or `verify*.py`. `peakdo/Wattline-SPEC.md` is read-only for this program.

---

## Plan Order and Review Gates

| Milestone | Plan | Working result |
|---|---|---|
| 1 | `2026-07-17-wattline-baseline-health.md` | Existing app/package/widget tests execute deterministically and green |
| 2 | `2026-07-17-wattline-device-catalog.md` | Saved devices, LAN discovery, and one-active-device switching on iOS |
| 3 | `2026-07-17-wattline-macos.md` | Menu-bar-first macOS app, optional window, and macOS widget |
| 4 | `2026-07-17-wattline-app-intents.md` | Three intents plus iOS/macOS Shortcuts galleries |
| 5 | `2026-07-17-wattline-expert-controls.md` | Protocol-accurate BLE PIN and factory-mode controls |
| 6 | `2026-07-17-wattline-release-verification.md` | Fresh deterministic builds, audits, Demo journeys, and external-evidence matrix |

Execute one plan completely, commit its tasks, deliver the specified handoff, and stop for approval before opening the next plan. A later milestone may consume only interfaces committed by earlier milestones.

## Simulator Selection

Never hardcode an iPhone model name. Set an installed simulator UUID once per shell:

```bash
xcrun simctl list devices available
export WATTLINE_SIMULATOR_ID='<installed iOS 17+ simulator UUID>'
```

Every iOS command uses:

```bash
-destination "platform=iOS Simulator,id=$WATTLINE_SIMULATOR_ID"
```

If Xcode reports `DebuggerVersionStore: no debugger version` or an install/launch denial before XCTest starts, record it as an environment failure, switch to a clean installed simulator, and rerun. A build-only result never substitutes for an executed test result.

## Coverage Index

| Approved design requirement | Owning plan/tasks |
|---|---|
| Current 11 unique app-test failures and deterministic baseline | Baseline Tasks 1–4 |
| Versioned saved devices, legacy migration, auto-reconnect preference | Device Catalog Task 1 |
| MAC-first/CID-fallback correlation and Bluetooth preference | Device Catalog Tasks 1 and 4 |
| Active `_wattline._tcp` discovery and manual VPN/Tailscale/WAN routes | Device Catalog Tasks 2 and 4 |
| One active device/session, explicit Router route, stale-generation quarantine | Device Catalog Tasks 3–5 |
| macOS one-owner MenuBarExtra, compact popover, Dock/login settings | macOS Tasks 1–3 |
| Optional macOS Home/Devices/Shortcuts/Settings window, no Timers | macOS Task 3 |
| macOS Notification Center widget embedding and snapshot-only read path | macOS Task 4 |
| Toggle DC, Get Battery, Set USB-C Limit and 10-second connection window | App Intents Tasks 1–2 |
| iOS/macOS capability-gated Shortcuts galleries and Demo labeling | App Intents Task 3 |
| BLE PIN exact bytes, no storage/read/delete, pairing guidance | Expert Tasks 1–3 |
| Factory-mode reply validation and route/capability absence | Expert Tasks 1–3 |
| Package purity, no cloud/OTA/Timers, Demo journeys, external evidence | Release Verification Tasks 1–5 |

No approved requirement is intentionally deferred inside these plans. The exclusions in the design remain excluded rather than appearing as unchecked work.
