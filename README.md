# hostflip

Native macOS hosts switcher. Flip between `/etc/hosts` profiles from your menu bar — no password prompt, no Electron, no fuss.

**Free and open source (MIT).** From the makers of [Heron](https://getheron.app/) — debug your iPhone's web traffic and console, from your Mac.

![hostflip main window: profile groups in the sidebar, the merged system hosts on the right](docs/screenshots/main-window.png)

## Why hostflip

Editing `/etc/hosts` by hand — or typing your password every time a hosts manager wants to save — gets old fast. hostflip is built around one idea: **switching should be zero-interruption**. You approve the privileged helper once; after that, every flip is a single click in the menu bar.

- **Native and lightweight.** Swift + SwiftUI menu bar app. No web runtime, no background bloat.
- **Zero-interruption switching.** A one-time approval of an embedded `SMAppService` daemon replaces per-switch password prompts.
- **A real activation model.** Profiles live in groups: at most one profile per group is active (mutually exclusive), while active profiles across groups and standalone profiles stack together into the final hosts file.
- **Your baseline is protected.** On first run, your current `/etc/hosts` is imported as the read-only *Base Hosts* — always applied first, never lost, and the original file is kept as a permanent backup.
- **External edits are respected, not clobbered.** If anything else modifies `/etc/hosts`, hostflip detects the drift and walks you through reconciling it in a diff view before it writes again.
- **Pause everything.** One master switch restores your baseline hosts while remembering every profile's state.

<p align="center">
  <img src="docs/screenshots/menu-bar.png" width="293" alt="Quick switching from the menu bar: standalone profiles on top, groups as submenus with each group's active profile shown as a badge">
</p>

![Drift review: external changes to the system hosts shown as a diff before reconciling](docs/screenshots/drift-review.png)

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

## FAQ

**I switched profiles, but my browser still resolves the old address.**

The system side is already complete — every write ends with a full DNS flush (`dscacheutil -flushcache` plus a `HUP` to `mDNSResponder`). What ignores it is the browser itself, in two layers: browsers keep a private DNS cache (roughly a minute), and — the bigger one — they keep established HTTP/2 and HTTP/3 connections alive for minutes. A reload rides an existing connection to the old address without resolving anything, which is why the behavior looks random and why restarting the browser "fixes" it. No hosts switcher can reach inside another process to clear these.

To pick up a switch without restarting the browser:

- **Chrome / Edge**: open `chrome://net-internals/#dns` (`edge://net-internals/#dns`) and click **Clear host cache**; then — the step that actually matters — `chrome://net-internals/#sockets` → **Flush socket pools**. A fresh incognito window also works: it gets its own DNS cache and connection pool (a plain new window shares them).
- **Firefox**: `about:networking#dns` → Clear DNS Cache. There is no UI for the connection pool, so a private window is the practical route.
- **Safari**: exposes neither; restart it or wait for idle connections to time out.
- DevTools' "Disable cache" does not help — it only affects the HTTP cache, not DNS or connection reuse.

To confirm the switch itself took effect, ask the system resolver directly: `dscacheutil -q host -a name your.host.name`. If that returns the new address, hostflip did its job and what you're seeing is browser-side.

One adjacent trap: with DNS-over-HTTPS enabled (Chrome's "Secure DNS", Firefox's TRR), some configurations bypass `/etc/hosts` entirely. That shows up as hosts entries *never* working — different from needing a browser restart.

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

Note that `/etc/hosts` keeps whatever hostflip last wrote — uninstalling does not rewrite it. Everything hostflip added sits in a clearly fenced block at the bottom of the file (`# ══ hostflip:begin … ══` through `# ══ hostflip:end ══`), so leftover entries are easy to spot and delete by hand. Better still, turn off the master switch **before** removing the helper: that restores the file to exactly your baseline hosts, with no hostflip traces at all — once the helper is gone, hostflip can no longer write the file. Your pre-hostflip hosts file is also preserved as `hosts.orig` in `~/Library/Application Support/hostflip` until that folder is zapped.

## License

[MIT](LICENSE)
