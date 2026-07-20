# Wattline Phase 2 SDD Progress

Branch base: 36108f38
Planning head: cf7b081c
Milestone 1: in progress
Task 1: complete (commits cf7b081c..5e20cc18, review clean after corrective commit)
Task 2: complete (commits 5e20cc18..8941e7be, review clean; Core 142/142 and iOS build-for-testing green; iOS runtime deferred to milestone gate due local DVTDeviceOperation/locked-device launcher failure)
Task 3: complete (commits 8941e7be..91d1fa33, review clean; WattlineUI 16/16, Core 142/142, iOS build/build-for-testing green)
Task 4: complete (commits 91d1fa33..669f7cb1, review clean; Core quirks 10/10, full Core 142/142, iOS build-for-testing green)
Task 5: complete (commits 669f7cb1..70e139f2, review clean; Core 142/142, lifecycle build-for-testing green; runtime XCTest unavailable)
Task 6: complete (Milestone 1 verification; Core 142/142, quirks 10/10, WattlineUI 16/16, iOS build-for-testing and generic arm build green; runtime/x86_64 external blockers documented)
Task 3: complete (commits 8941e7be..91d1fa33, review clean; WattlineUI 16/16, Core 142/142, generic iOS build/test-build green)
Task 7: complete (commits 70e139f2..dd2820cd, review clean after test-strengthening fix; Core 145/145)
Task 8: complete pending fresh re-review (commits 70e139f2..da73605b; Core 148/148)
Task 8: complete (commits 70e139f2..da73605b, review clean after port-status correction; Core 148/148)
Task 9: complete (commit 47d75c12; review clean; focused 3/3; mutation RED evidence; report finalized in 9fa93ca7)
Task 10: complete (commits 84faeec9..6c335d87, review clean after AppModel and production app-group wiring; generic iOS build-for-testing green)
Task 11: complete (commits 593b02b0..ea938479, review clean after broker/result/prefs/threshold fixes; generic iOS build-for-testing green)
Task 12: complete (Core 151/151, UI suite green, generic iOS build-for-testing green; static audits complete; runtime/background/hardware checks external)
Task 13: complete (commit 819fb9e8, review clean; focused 3/3; Core 154/154)
Task 14: complete (commits 819fb9e8..1bbd166e, review clean after scoped configuration assertions and path corrections; generic widget iOS/macOS builds green)
Task 15: complete (commits ba562419..5cd68f93, review clean after aggregate output filtering, disconnected timestamp, ContentState, and nil-mode telemetry fixes; generic iOS build-for-testing green)
Task 16: complete (commits b13b3bf5..fc39031a, review clean after reload/deep-link/unavailable integration and test corrections; generic iOS build-for-testing green; Core 154/154)
Network stream Task 1: complete (commits a45034e0..faab636c, review clean after hardened Core networking audit; WattlineNetwork boundary 2/2, Core 154/154)
Network stream Task 2: complete (commits 6cf71ea2..b9d6d4cc, review clean after real URLSession/URLProtocol coverage and restored incremental SSE; Network 11/11)
Network stream Step 0: complete (commit fdcbd71b, review clean; UTF-8 split-chunk regression and Network 12/12)
Network stream Task 3: complete (commit 65fe6ef7, review clean; mapping 5/5, Network 17/17, Core 154/154)
Network stream Task 4: complete (commits 8466f576..f375f4e9 plus fixture barrier fix; review clean after lifecycle, credential, lifetime, replacement-scope, and cancellation fixes; transport 23/23, Network 49/49, Core 154/154, UI 26/26)
Network stream Milestone 2 review corrections: complete (commit 4439e311; actor-gated stale publication, URL cancellation/transport errors, lifecycle-free mapping, monotonic clock-step policy; Network 55/55 before final handoff verification)

## Non-OTA Completion — Milestone 1: Baseline Health

Planning head: 18c38822
Baseline Task 1: complete (commits 18c38822..67070855, review clean after deterministic pending-fan-out fix; 18/18 focused tests and 8/8 covering re-run green)
Baseline Task 2: complete (commits 67070855..c7c61552, review clean after stale-broker, nonmatching-telemetry, and session-poisoning fixes; 49/49 focused and 16/16 broker green)
Baseline Task 3: complete (commits c7c61552..4021b5fb, review clean after exact-scope signal, exact-once ownership, stale-generation, and deterministic overlap fixes; lifecycle 14/14, reconnect 44/44, quirks 10/10 green)
Baseline Task 4: complete (commits 4021b5fb..c223015d, review clean after full-suite blocker fixes; Core 156/156, UI 26/26, Network 97/97, Wattline 148/148, WattlineWidgets 148/148; audits clean)

## Router Administration — Milestone 2

Router Administration Task 6: complete (commits 0808b54f..520033ca, review clean after client-only coexistence regression; Network 110/110)
Router Administration Task 7: complete (commits 520033ca..2071ac71, review clean after generation-safe credential persistence and clear/verification ordering fixes; Network 122/122, Wattline 187/187)
Router Administration Task 8: complete (commits 2071ac71..e1f48525, review clean after latest-request history ordering, deterministic initial load, honest load states, and admin/history generation isolation; Network 124/124, UI 32/32, Wattline 202/202)
Router Administration Task 9: complete (commits e1f48525..2713c451, review clean after stale-auth/status/QR ordering, secret lifecycle, expiry actionability, retryable failures, and exact PNG validation; Network 131/131, Wattline 223/223)
Router Administration Task 10: complete (commits 2713c451..6d0ad0b8, review clean after durable revoke cleanup, mandatory relist, credential revision leases, and attachment-bound pre-dispatch gating; Network 140/140, Wattline 245/245)
Router Administration final review corrections: complete (commits 1cb6cd54..75016b27, review clean after exact-200 enforcement, FIFO admin workflows, endpoint-bound queued mutations, versioned enrollment availability, and nil-preserving aggregate/DC/Type-C history series; Network 147/147, UI 33/33, Wattline 247/247)
Router Administration Task 11: complete at 75016b27 (Core 156/156, UI 33/33, Network 147/147, Wattline 247/247, WattlineWidgets 247/247, generic iOS Simulator build green; audits and final evidence review clean; M3 not started)

## Router Administration — Milestone 3

M3 Step 0: complete (commit e325cb76; detailed Tasks 12–15 plan grounded in approved M2 interfaces and router API)
Router Administration M3 Task 12: complete (commits e325cb76..d8d8a009; review clean after BLE-PIN description redaction; Network 155/155)
Router Administration M3 Task 13: complete (commits d8d8a009..8801d1c0; review clean after candidate-survival, redirect-containment, and UI PIN-redaction fixes; UI 42/42, Network 159/159, focused app 75/75, generic iOS build green)
Router Administration M3 Task 14: complete (commits 8801d1c0..cfe205ca; review clean after post-restart reachability, TLS-control serialization, strict identity/endpoint CAS, and exact-wire fixes; Network 174/174, UI 42/42, focused app 86/86, generic iOS build green)

## Router Administration — Milestone 5

M5 approved base: 845d8529
M5 Step 0: complete (commit 35d8b321; 731-line detailed Tasks 20–24 plan; fresh baseline Core 156, UI 58, Network 217)
M5 Task 20: complete (commits 35d8b321..58b13633; review clean after exact-number/future-condition fix; RouterRules 23/23, Network 240/240)
M5 Task 21: complete (commits 58b13633..2068f4aa; review clean after complete-editor, human-duration, stale-state, and immutable-name fixes; UI 64/64, model 132/132, iOS 309/309)
M5 Task 22: complete (commits 2068f4aa..6a3049e2; review clean after functional shared-admin, scheme, enrollment navigation, and lifecycle hardening; Mac 12/12, iOS 313/313, Widgets 313/313, generic Mac build green)
M5 Task 23: complete (base 6a3049e2; UI 64/64, iOS 319/319, Mac 14/14; deterministic no-write Demo, complete cross-platform administration, accessibility semantics, and audits green; Task 24 not started)
