# Task 18 review corrections

## Findings addressed

- Split advanced load and mutation generations so an overlapping authoritative reload cannot strand the mutation gate.
- Quarantine cancelled, cancellation-insensitive advanced completions before publication.
- Reset all advanced operation and per-surface capability state when authoritative settings disable Advanced.
- Refresh authoritative settings after `advanced_disabled` before showing the settings recovery affordance.
- Clear the view-local BLE PIN whenever its structurally gated surface disappears.
- Replace the class-description PIN assertion with recursive stored-property reflection.

## RED evidence

- `/tmp/wattline-m4-task18-review-ui-red.log`: `RouterAdvancedSecretPolicy` missing; suite failed to compile.
- `/tmp/wattline-m4-task18-review-app-red.log`: overlap regression failed.
- `/tmp/wattline-m4-task18-review-app-red-all.log`: four expected failures:
  - `testAdvancedDisabledPublishesSettingsEditorAffordance`
  - `testAdvancedReloadOverlappingMutationDoesNotStrandMutationGate`
  - `testCancelledAdvancedMutationCannotPublishInsensitiveCompletion`
  - `testSavingAdvancedOffClearsPerSurfaceCapabilityQuarantine`

## GREEN evidence

- `/tmp/wattline-m4-task18-review-ui-green.log`: 7/7 focused presentation tests passed.
- `/tmp/wattline-m4-task18-review-app-green.log`: full `RouterAdministrationModelTests` selection passed on `Wattline-Tests-2`.

No Milestone 5 source was added.
