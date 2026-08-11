# Helper re-registration field test: approval retention and the BTM settling window

Answers the spec's open verification item "does helper re-registration trigger
re-approval" (the premise behind the upgrade strategy in the permission-model
ADR-0002), and records the factual basis for the `healOnLaunch` backoff
retries in #19.

## Conclusion (tested 2026-08-07, macOS 26.6 / Darwin 25.6.0)

**`unregister()` + `register()` does not trigger re-approval**: the approval
record is bound to the app's signing identity; after unregistering, re-registering
goes straight back to `enabled`, with no system prompt and no round trip through
System Settings at any point. The upgrade strategy stays as "`CFBundleVersion`
change → `unregister()` + `register()`"; there is no need to narrow it to
"re-register only when the helper's contents change".

Additional facts from the same test batch:

- **First-registration flow**: `register()` throws, yet the registration has
  already taken effect (the status lands on `requiresApproval` and the system
  posts a notification) — validating the state machine's design of trusting the
  after-the-fact `status` rather than the thrown error. After approving the
  toggle in System Settings (no administrator password was required on this
  machine), the status became `enabled`.
- **Swapping the binary does not drop the approval**: overwriting the app
  bundle in place with a new-version build (without re-registering) kept the
  status `enabled`, and launchd launched the daemon on demand with the new binary.
- **BTM settling window**: `unregister()` lands asynchronously on the BTM side;
  until it settles (roughly 0.5–4 seconds in testing, and equally restricted
  across processes), every `register()` call is rejected and the status stays at
  `notRegistered`. Both `healOnLaunch` and the switch path's lazy registration
  cover this window with 500ms × 12 backoff retries (one test run completed
  re-registration within 1.2 seconds); if it still fails within that limit, they
  give up and let the next switch's lazy registration converge — the approval
  is retained, still zero-interruption.

## Limitations

- The settling-window duration comes from a small number of samples on a single
  machine, and in one run all 10 retries within 1.8 seconds failed;
  500ms × 12 is an engineering value with headroom, not a guarantee, hence the
  lazy-registration fallback path is kept.
- The approval toggle not requiring an administrator password is an observation
  from this machine (an administrator account); standard accounts were not
  tested. This does not affect the strategy — approval is always a manual action
  the user performs in System Settings.

## Reproduction steps

The whole flow can be scripted with the signed build's diagnostic commands
(`--switch` / `--heal` / `--unregister` / `--status`; see HostflipMain.swift):

1. Install signed build v1 (`CFBundleVersion` 1) into `~/Applications`;
   `--status` confirms `notFound` (never registered).
2. `--switch` → prints `blocked=needsApproval`, `--status` lands on
   `requiresApproval`, and `/etc/hosts` is untouched — verifying lazy
   registration + blocking while unapproved.
3. In System Settings > General > Login Items & Extensions, turn on Hostflip's
   background toggle → `--status` immediately shows `enabled`; `--switch` prints
   `merged hash=…`, `/etc/hosts` is replaced with the merged output, and
   `/etc/hosts.prev` rolls over — verifying zero-interruption operation after
   approval.
4. Change `CFBundleVersion` to 2, rebuild signed, and install over the existing
   bundle → `--status` still `enabled` (swapping the binary does not drop the
   approval).
5. `--heal` triggers the version-change re-registration → prints `enabled`, with
   no prompt at any point — the core conclusion. (Settling-window observation:
   with the retry interval squeezed to 200ms × 10, this step once ended in
   `notRegistered`; a few seconds later a fresh process running `--switch`
   restored `enabled`.)
