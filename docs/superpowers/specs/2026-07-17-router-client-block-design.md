# Router Client Block Design

## Protocol findings

`ClientConfig.WeeklyBlockSchedules` is field 5. Each `WeeklyBlockSchedule`
has `block_ranges` and `group_id`; each range supplies only `start_minutes`
and `end_minutes`. There is no day field, so the schedule's only complete
all-week representation is one range in minutes-of-week: `[0,10080)`. The
Starwatch-owned schedule uses group ID `starwatch-block`.

`WifiClient.Blocked` is the live confirmation signal. The targeted
`WifiSetClientGivenName` request carries the full `ClientConfig`, including
weekly schedules. The in-process Handle fake will apply that full config and
update `Blocked`; Phase 5 therefore continues to use request field 3017 rather
than `WifiSetConfig`/`ApplyClientConfigs`, avoiding atomic collection resend.

## Backend design

`PATCH /api/router/clients/{mac}` accepts exactly one mutation per request:
either a non-empty `given_name` with `RENAME CLIENT`, or `blocked:true|false`
with `BLOCK CLIENT`/`UNBLOCK CLIENT`. This keeps confirmation semantics
unambiguous. The existing revision, topology, reachability, MAC normalization,
fresh-config TOCTOU check, targeted RPC, and dual readback path are reused.

Block clones the target `ClientConfig`, appends exactly one
`starwatch-block` schedule containing `[0,10080)`, and preserves the name,
identity, group, and user schedules. Unblock removes only schedules with that
group ID. If a remaining user schedule blocks the client, it returns a conflict
without a write. Live `WifiClient.Blocked` must equal the requested value before
202. Confirmed `block_client` and `unblock_client` audits contain exactly the
secret-free `action`, normalized `mac`, `result`, and `client_id` fields; they
omit `given_name`. Rename retains its name-bearing five-field audit schema.

## SPA design

The topology-B-only client-management card reads `/api/router`, lists client
identity, connection, radio, throughput, and blocked state, and sends one
mutation per action. Inline rename uses the rename confirmation. A block toggle
opens a typed-confirmation dialog. On 409 it refreshes router telemetry and
offers retry with the new revision. The card neither shows nor requests a
passphrase.
