# DNS flush testing: mDNSResponder's detection of hosts changes

Answers the spec's open empirical question — "does mDNSResponder detect hosts
changes on its own" — and records the factual basis for the fixed flush
commands in #18 (`dscacheutil -flushcache` + `killall -HUP mDNSResponder`).

## Conclusion (tested 2026-08-07, macOS 26.6 / Darwin 25.6.0)

**mDNSResponder detects content changes to `/etc/hosts` on its own**: within
1 second of appending a record, all three lookup paths — `dns-sd -G v4`
(talks directly to mDNSResponder), `dscacheutil -q host`, and `getaddrinfo` —
returned the new record, with no flush command executed in between.

Additional facts:

- `dscacheutil -flushcache` runs without root (exit code 0).
- This machine has a fake-IP proxy providing fallback DNS answers (at
  baseline the probe domain resolved to 198.18.9.216); after the append, all
  three paths immediately switched to answering `127.0.0.1` — the hosts
  record instantly overrode the upstream answer, so attribution is
  unambiguous.

**The design is unchanged**: the daemon's fixed transaction still explicitly
runs both flush commands. Self-detection is an observed behavior of the
current OS version, not a promised one (Apple's support documentation still
calls for a manual flush); explicit flushing guarantees that a replacement
takes effect immediately on any macOS version, at negligible cost.

## Limitations

- The test triggered detection via an **append write** (relying on this
  machine's /etc/hosts having been left at 666 by a third-party tool, see
  below), whereas the daemon uses an **atomic rename replacement**. vnode
  monitoring emits different events for the two (write vs rename), and
  self-detection on the rename path was not verified separately — but the
  daemon always flushes explicitly, so this difference does not affect
  product behavior.
- `killall -HUP mDNSResponder` requires root; a non-root test cannot verify
  the HUP branch in isolation. It is covered by the signed daemon's
  integration verification (the channel round-trip in
  docs/signed-build-verification.md).

## Reproduction steps

The probe script takes a byte-for-byte snapshot of /etc/hosts and restores
it, entirely without root (relying on the current 666 permissions; a machine
with normal permissions must run it as root):

1. Baseline: run each of `dscacheutil -q host -a name <probe>`,
   `getaddrinfo`, and `dns-sd -G v4 <probe>` once.
2. `printf '127.0.0.1 <probe>\n' >> /etc/hosts`.
3. Repeat the three queries immediately, at +5s, and at +15s — in this test
   all three time points already returned `127.0.0.1`.
4. Query again after `dscacheutil -flushcache` (results unchanged).
5. Restore the snapshot and verify the bytes match with `cmp`.

## Incidental finding

At test time this machine's `/etc/hosts` was `666 root:wheel` (left behind
by SwitchHosts) — any local process can rewrite it, i.e. the DNS hijacking
vector called out by the permission model (ADR 0002). hostflip's fixed
transaction resets the target to `644 root:wheel` on every replacement, so
the first merged write closes this gap.
