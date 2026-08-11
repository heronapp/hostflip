# hostflip

Native macOS hosts switcher. Flip between `/etc/hosts` profiles from your menu bar — no password prompt, no Electron, no fuss.

**Free and open source (MIT).** From the makers of [Heron](https://getheron.app/) — debug your iPhone's web traffic and console, from your Mac.

## Why hostflip

Editing `/etc/hosts` by hand — or typing your password every time a hosts manager wants to save — gets old fast. hostflip is built around one idea: **switching should be zero-interruption**. You approve the privileged helper once; after that, every flip is a single click in the menu bar.

- **Native and lightweight.** Swift + SwiftUI menu bar app. No web runtime, no background bloat.
- **Zero-interruption switching.** A one-time approval of an embedded `SMAppService` daemon replaces per-switch password prompts.
- **A real activation model.** Profiles live in groups: at most one profile per group is active (mutually exclusive), while active profiles across groups and standalone profiles stack together into the final hosts file.
- **Your baseline is protected.** On first run, your current `/etc/hosts` is imported as the read-only *Base Hosts* — always applied first, never lost, and the original file is kept as a permanent backup.
- **External edits are respected, not clobbered.** If anything else modifies `/etc/hosts`, hostflip detects the drift and walks you through reconciling it in a diff view before it writes again.
- **Pause everything.** One master switch restores your baseline hosts while remembering every profile's state.

## Install

**Homebrew**

    brew tap heronapp/tap
    brew trust heronapp/tap   # newer Homebrew requires trusting third-party taps once
    brew install --cask hostflip

**Direct download**

Grab the notarized DMG from [Releases](https://github.com/heronapp/hostflip/releases/latest) and drag `Hostflip.app` into `/Applications`.

Requires macOS 14 or later on Apple silicon.

## How it works

hostflip owns the whole `/etc/hosts` file and rewrites it atomically: Base Hosts first, then every active profile, each section clearly labeled. Writes go through a minimal root daemon whose XPC interface accepts exactly one operation — replace the hosts file with merged content — with code-signing verification on both sides of the connection. The daemon flushes the DNS cache after every write.

The first time you actually switch something, macOS asks you to approve the helper in System Settings. That's the only prompt you will ever see.

Technical deep-dives live in [`docs/`](docs/): signed-build verification, helper re-registration behavior, DNS flush measurements, and the release pipeline, all with reproducible steps.

## Updating

- Homebrew: `brew upgrade --cask hostflip`
- In-app: “Check for Updates” compares your version against the latest GitHub Release.

## Build from source

    swift build            # library & executables
    swift test             # test suite
    scripts/build-app.sh   # assemble Hostflip.app (ad-hoc signed without CODESIGN_IDENTITY)

An ad-hoc build verifies the packaging structure, but the XPC channel intentionally fails closed without a real Developer ID identity — see `docs/signed-build-verification.md`.

## Uninstall

Use “Deactivate and Remove Helper…” in the app first (unregisters the daemon), then delete `Hostflip.app`. `brew uninstall --zap --cask hostflip` also clears application data.

Note that `/etc/hosts` keeps whatever hostflip last wrote — uninstalling does not rewrite it, and entries from profiles that were active stay in effect. If you want only your baseline hosts applied, turn off the master switch (which restores Base Hosts) **before** removing the helper; once the helper is gone, hostflip can no longer write the file. Your pre-hostflip hosts file is preserved as `hosts.orig` in `~/Library/Application Support/hostflip` until that folder is zapped.

## License

[MIT](LICENSE)
