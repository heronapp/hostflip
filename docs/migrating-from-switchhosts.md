# Migrating from SwitchHosts

hostflip reads SwitchHosts data directly — every generation of it (v3, v4 and v5) — and turns it into hostflip profiles in one step. This page explains what carries over, what changes, and the order of operations that keeps your hosts file clean during the switch.

## Before you start

1. **Quit SwitchHosts.** On first launch hostflip takes a snapshot of the current `/etc/hosts` as your read-only *Base Hosts* — the baseline it always applies first and never loses. hostflip recognises the block SwitchHosts appends below its `# --- SWITCHHOSTS_CONTENT_START ---` marker and keeps it out of that baseline, so rules that happen to be on do not get welded in — you can leave them as they are. The rules below the marker are not kept either; if you want them, import them from your SwitchHosts data. Quitting SwitchHosts simply avoids two tools writing the same file, which would trip hostflip's drift review on every save.
2. **Keep your SwitchHosts data where it is.** hostflip only reads it; nothing is moved or deleted. `~/.SwitchHosts` keeps working as a backup for as long as you want it.

## Import

hostflip notices SwitchHosts data on first launch and offers to import it. You can also run **File → Import from SwitchHosts…** at any time.

hostflip looks in `~/.SwitchHosts`, then in the custom data directory a v5 install may point to, then in the v4 archives a v5 upgrade leaves under `~/.SwitchHosts/v4/`. If none of them holds rules, it asks you to pick the folder yourself — either the data directory or its `SwitchHosts.data` subfolder works.

The import is all-or-nothing: either everything lands, or nothing changes.

## What carries over

| In SwitchHosts | In hostflip |
|---|---|
| Local rule | Profile with the same content |
| Folder | Group. Nested folders are flattened into one group named `Outer / Inner` |
| Rule at the top level | Standalone profile |
| Remote rule | Remote Profile that keeps refreshing on its own. Refresh interval rounds to the nearest hostflip tier: off → manual, anything up to 1 h → 1 h, 24 h → 24 h, 7 days → 24 h |
| Combined rule (`group` type) | A profile holding the combined content as a snapshot. It no longer follows its members |
| System hosts entry | Skipped — Base Hosts already plays that role |
| History snapshots | Skipped |
| Trash | Skipped, with a count in the summary |

Two things are deliberately **not** carried over:

- **On/off state.** Everything arrives inactive. You decide what goes live, one switch at a time, after reviewing the result.
- **Multi-select folders.** A folder becomes a group, and a group in hostflip is mutually exclusive: at most one profile in it is active. If you relied on stacking several rules inside one folder, move those profiles out of the group — standalone profiles stack freely with each other and with every group's active profile.

The import summary lists every mapping, every skip, and every adjustment it made.

## What works differently

- **One approval, no more prompts.** hostflip installs a small root helper once; after that, every switch is a single click in the menu bar — including scheduled remote refreshes.
- **Your baseline is protected.** Base Hosts is applied first and cannot be edited away. The pre-hostflip file is also kept as `hosts.orig` in `~/Library/Application Support/hostflip`.
- **Nothing gets clobbered.** hostflip writes its entries inside a clearly fenced block at the end of `/etc/hosts`. If anything else edits the file, hostflip stops writing and shows you the difference before it continues.
- **Pause everything.** The master switch restores Base Hosts while remembering every profile's state.
- **Command line.** The bundled `hostflip` tool switches profiles from scripts, and `hostflip doctor your.host.name` checks the whole chain — profiles → merge → file → resolver — in one command.

## What you give up

hostflip is Mac-only (macOS 14+, Apple silicon). There is no Windows or Linux build, combined rules are snapshots rather than live compositions, remote sources must be HTTPS, and there is no Alfred workflow. If you need any of those, SwitchHosts remains the right tool.

## After import

1. Activate profiles from the menu bar and confirm the switch with `hostflip doctor your.host.name`.
2. Quit SwitchHosts for good, or at least leave all its rules off. Two tools writing `/etc/hosts` will trip hostflip's drift review every time the other one saves.
3. If your browser still resolves the old address, that is the browser's own DNS and connection cache — see the README FAQ for the per-browser fix.

## If your Base Hosts already contains SwitchHosts rules

Workspaces captured by hostflip 0.3.0 or earlier took the whole file, SwitchHosts block included. To clean that up: remove the `# --- SWITCHHOSTS_CONTENT_START ---` line and everything below it from `/etc/hosts` by hand (with SwitchHosts quit), wait for hostflip to report the drift, and accept the reviewed file as your new Base Hosts in the drift review. The original file stays untouched as `hosts.orig`.

## If the SwitchHosts v5 upgrade lost your data

Some v4 → v5 upgrades have left users with an empty rule list. v5 moves the old data into `~/.SwitchHosts/v4/migration-<timestamp>/`. When the live v5 store reads cleanly but holds no rules, hostflip skips it and imports from the newest of those archives whose `data` directory survived — no folder picking needed; the import summary names the format it read (v4). A store that cannot be read at all is reported as a failed import instead, with a button to pick the folder yourself. If no archive kept its `data` directory, the rules did not survive the upgrade and hostflip cannot recover them either.
