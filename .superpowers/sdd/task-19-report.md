# Router Administration Milestone 4 — Task 19 verification

Verified from `d983528a` through `9607b434` on 2026-07-20. Milestone 5 was not started.

## Commits

- `9c67de66` `docs: plan router administration milestone 4`
- `05f2ff32` `docs: refine router administration milestone 4 plan`
- `fda85e7d` `feat: pair Link-Power through router`
- `756ae9a2` `fix: align router device pairing contract`
- `0c4b4864` `fix: quarantine router pairing progress`
- `8d40dfdf` `feat: add router advanced device controls`
- `ecca11d5` `fix: validate router running modes`
- `653ff6c4` `feat: present router device administration`
- `093f414d` `fix: harden advanced administration lifecycle`
- `b171db30` `docs: verify router administration milestone 4`
- `b45ea494` `fix: gate advanced controls from router features`
- `9607b434` `fix: quarantine cancelled capability refresh`

Before this report's finalization commit, the milestone diff contains 21 files, 3,981 insertions, and 27 deletions.

## TDD evidence

### Task 16

- Initial Network RED: missing `RouterDevicePairingClient` and `RouterDevicePairingError` (`/tmp/wattline-m4-task16-network-red.log`).
- Initial UI RED: missing pairing presentation/value types (`/tmp/wattline-m4-task16-ui-red.log`).
- Review REDs then caught the daemon stage mismatch, missing progress API, caller-cancellation gaps, action-composition gaps, gated-terminal false success, and 409-unpair premature completion.
- Final GREEN: pairing Network 19/19; full Network 204/204; pairing UI 6/6; full UI 51/51; app 281/281.
- Full detail: `.superpowers/sdd/task-16-report.md`.

### Task 17

- Initial RED: advanced DTO/client APIs absent (`/tmp/wattline-m4-task17-red.log`).
- PIN RED: daemon errors reflected `020555` (`/tmp/wattline-m4-task17-pin-red.log`).
- Review RED: mode 2 incorrectly dispatched a third PUT (`/tmp/wattline-m4-task17-mode-red.log`).
- Final GREEN: focused advanced API 13/13; full Network 217/217; queued stale-operation stress 20/20.
- Full detail: `.superpowers/sdd/router-admin-m4-task-17-report.md`.

### Task 18

- Initial UI RED: advanced visibility/value types absent (`/tmp/wattline-m4-task18-ui-red.log`).
- Initial app RED: advanced model members absent (`/tmp/wattline-m4-task18-app-red.log`).
- Initial GREEN: UI 57/57; Network 217/217; app 288/288.
- Review REDs proved the overlapping reload gate strand, cancelled-completion publication, stale capability quarantine after Advanced-off, ineffective stale-settings 403 affordance, and BLE-PIN visibility lifecycle gap (`/tmp/wattline-m4-task18-review-*.log`).
- Whole-milestone review then proved that factory-mode proxies incorrectly exposed independent router features, that a 409 quarantined a control before authoritative refresh succeeded, and that cancellation could land between refresh and quarantine commit. RED logs: `/tmp/wattline-m4-finalfix-network-red.log`, `/tmp/wattline-m4-finalfix-ui-red.log`, `/tmp/wattline-m4-finalfix-app-red.log`, and `/tmp/wattline-m4-finalcancel-red.log`.
- Corrected GREEN: feature decode 6/6, advanced UI 7/7, and the full `RouterAdministrationModelTests` suite green after both correction waves (`/tmp/wattline-m4-finalfix-network-green.log`, `/tmp/wattline-m4-finalfix-ui-green.log`, `/tmp/wattline-m4-finalfix-app-green.log`, `/tmp/wattline-m4-finalcancel-green.log`). Independent re-review approved `9607b434` with no new findings.
- Full detail: `.superpowers/sdd/task-18-review-fixes.md`.

## Final executed suites

Simulator for all Xcode runs:

- `Wattline-Tests-2`
- iPhone 17e, iOS 26.5 (23F77), arm64
- UDID `74C1DA4D-7190-4497-AAD5-9EB140B3A96A`

Results:

- WattlineCore: **156/156**, 0 failures (`/tmp/wattline-m4-final-core.log`).
- WattlineUI: **58/58**, 0 failures (`/tmp/wattline-m4-final-ui.log`).
- WattlineNetwork: **217/217**, 0 failures (`/tmp/wattline-m4-final-network.log`).
- Wattline app scheme: the reviewed exact all-in-one final-source run executed **293/293** with 0 failed/skipped/expected.
- WattlineWidgets scheme: the reviewed exact all-in-one final-source run executed **293/293** with 0 failed/skipped/expected.
- Generic iOS Simulator build from final source: `** BUILD SUCCEEDED **` (`/tmp/wattline-m4-build-final.log`).

Earlier environmental attempts included a 19-minute `DebuggerLLDB.DebuggerVersionStore.StoreError` hang and UI-event scheduling timeouts. The interim decomposed evidence of 277 non-UI plus 16 UI tests was not the final scheme result; the reviewed clean combined result is 293/293 for both Wattline and WattlineWidgets. The failed environmental attempts remain retained in `/tmp/wattline-m4-widgets.log`, `/tmp/wattline-m4-widgets-combined-final.log`, and their xcresults; no assertion failure originated in Milestone 4 production code.

## Audit transcript

Final commands, output, and exit codes are in `/tmp/wattline-m4-audits-final.log`; the broad identifier audit is retained in `/tmp/wattline-m4-extra-audits.log`.

- Core/UI `URLSession|NWBrowser|NWConnection|import Network|import Security`: no matches, exit 1.
- WattlineUI source `import WattlineNetwork`: no matches, exit 1.
- WattlineUI `Package.swift` `WattlineNetwork`: no matches, exit 1.
- Deprecated routes `/device/action|/device/usbc-limit|/device/bypass-threshold|/device/schedules`: no matches, exit 1.
- Admin-side `BLETransport|DeviceSession(|DeviceOperationBroker`: no matches, exit 1.
- Milestone 5 `/api/v1/rules|/api/v1/device/ota`: no matches, exit 1.
- Broad logging grep: exit 0 with 125 hits; every hit is the semantic false-positive substring `print` inside `Fingerprint`/`fingerprint`. Refined logging-call grep has no matches, exit 1.
- UserDefaults-near-PIN/token/private-key: no matches, exit 1.
- Forbidden contract/OEM diff: empty, exit 0.
- `DeviceCommand.swift` and `RouterTransport.swift` diff from base: empty, exit 0; the six-argument initializer is unchanged.
- `git diff --check d983528a..HEAD`: clean, exit 0.
- Final status before editing this report: clean.

## Deviations from the Step 0 plan

- Task 16 adopted the live daemon’s exact stages (`idle/scanning/pairing/paired/error`) and its 0–6 ASCII-digit pairing PIN compatibility rule after verifying the router implementation. This corrects the initial plan’s too-strict six-or-empty interpretation without weakening the advanced BLE-PIN rule.
- A daemon-owned 409 operation is adopted and polled to terminal state; DELETE is never retried. UI action composition uses both local and authoritative busy state.
- Task 17 added strict BLE-PIN response/error reflection redaction and rejected unsupported running mode 2 before HTTP dispatch.
- Task 18 split load and mutation generations, refreshed authoritative settings after `advanced_disabled`, and added a pure visibility-transition secret policy after independent review exposed lifecycle races not anticipated by the initial plan.
- Task 18 replaced factory-mode proxy gates with exact, independently decoded router feature fields. Capability quarantine is now committed only after a successful authoritative settings/identity refresh and a post-refresh cancellation check.
- Simulator-runner investigation temporarily decomposed the widget targets and included failed environmental attempts, but those were superseded by reviewed clean exact combined Wattline and WattlineWidgets gates at **293/293** each. The previous app count and split-widget wording were report undercounts, not final product gaps.

## External live-router/hardware checks

Unit/simulator tests cannot prove:

- physical BlueZ scan, pair, and unpair against a Link-Power;
- empty-PIN retention of the router’s configured PIN;
- real bypass-threshold and barrier-free authoritative readback;
- real clock drift, sync, and `available:false` zero-BLE-I/O behavior;
- running-mode and BLE-PIN effects on hardware;
- live-daemon distinction between `advanced_disabled` and `capability_unsupported`.

Milestone 4 stops here. No rules, macOS administration, Demo administration fixtures, OTA, or timers were added.
