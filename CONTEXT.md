# hostflip

Native macOS hosts switcher: manages multiple hosts profiles under a "mutually exclusive within a group, merged across groups" model, and merges them into the system hosts file.

## Language

**Profile**:
A block of hosts content that can be enabled and disabled on its own; the smallest unit of switching.
_Avoid_: hosts file, rule, config

**Group**:
A container for profiles; at most one profile in a group is active, and active profiles from different groups stack together.
_Avoid_: folder, category

**Standalone Profile**:
A profile that belongs to no group; toggled independently, stacking with all other active content.
_Avoid_: independent profile, ungrouped profile

**Standalone Area**:
Where standalone profiles live; profiles can move between groups and the standalone area, and deleting a group releases its members back here.
_Avoid_: ungrouped area, root directory

**Base Hosts**:
The protected baseline captured from the system hosts on first run; always applied, shown read-only, cannot be deleted, and only updated through the controlled drift-reconciliation flow.
_Avoid_: system hosts (reserve that term for the real /etc/hosts file)

**System Hosts**:
The current content of the real `/etc/hosts`; shown live and read-only in the main window, and not part of the workspace.
_Avoid_: Base Hosts

**Active**:
The state of a profile that is selected and participates in the merge.
_Avoid_: enabled, turned on

**Merge**:
The act of concatenating Base Hosts with every active profile's content and writing the result to the system hosts file.
_Avoid_: apply, sync

**Paused**:
The state after the master switch is turned off; only Base Hosts is written to the system hosts file, while every profile's active state is preserved.
_Avoid_: disabled, deactivated

**Resume**:
The act of turning the master switch back on, ending the Paused state; every preserved active profile re-enters the merge.
_Avoid_: unpause, re-enable

**Dock Icon Visibility Policy**:
Controls how the app's Dock icon is shown — "When Main Window Is Open", "Always", or "Never"; does not affect the always-visible menu bar entry.
_Avoid_: menu-bar-only mode, menu bar switch

**Launch at Login**:
Whether hostflip registers itself as a login item to start automatically at login; login launches stay silent in the menu bar without opening the main window.
_Avoid_: auto-start, boot launch

**Appearance**:
The app-wide light/dark preference — Auto (follow the system), Light, or Dark; a forced choice applies to every hostflip window, while the menu bar icon always follows the menu bar itself.
_Avoid_: theme, dark mode

**Language**:
The app-wide language preference — System (follow the system) or one of the shipped languages; shares its stored state with macOS's per-app language setting and takes effect after relaunching hostflip.
_Avoid_: locale (for this setting), translation setting

**Workspace**:
hostflip's persistence directory; holds Base Hosts, the profile files, the manifest, and the original backup from first capture (hosts.orig).
_Avoid_: data directory, config directory

**Drift**:
The state where the current system hosts content differs from what hostflip last confirmed; means there are unreconciled external modifications.
_Avoid_: external change, conflict

**Export**:
A portable snapshot of every profile and the group structure; excludes Base Hosts and all active state.
_Avoid_: backup, dump

**Import**:
Appending external content to the workspace as new, inactive profiles and groups; never changes existing content or the system hosts.
_Avoid_: restore, load
