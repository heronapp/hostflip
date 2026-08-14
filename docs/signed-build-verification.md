# Signed build integration verification

Automated tests cover protocol encoding/decoding and error mapping
(`Tests/HostflipXPCTests`); signing identity validation and real XPC
connections can only be verified on a signed build, as follows.

## 1. Build and sign

    CODESIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/build-app.sh

Without `CODESIGN_IDENTITY` set, an ad-hoc signature is used: it verifies the
packaging structure, but carries no Team ID, so both sides of the channel fail
closed (which is exactly what the negative verification in step 4 relies on).

## 2. Verify the signature and requirement

    codesign --verify --strict --deep build/Hostflip.app
    build/Hostflip.app/Contents/MacOS/Hostflip --print-requirement
    build/Hostflip.app/Contents/MacOS/hostflipd --print-requirement

The Team IDs in the two requirements must match. The app prints the daemon
identifier `com.heronapp.hostflip.daemon` (the peer it requires); the daemon
prints an alternation accepting either client identifier:
`(identifier "com.heronapp.hostflip" or identifier "com.heronapp.hostflip.cli")`.

## 3. Channel round trip (requires sudo)

The production path is SMAppService registration (wired up in #19: lazy
registration on `--switch` plus approval in System Settings; for reproduction
steps see [helper re-registration verification](./helper-reregistration-verification.md)).
The manual launchctl load in this section bypasses the approval flow and is
still used to verify the channel round trip and the step 4 negative scenarios
without interaction. The plist must live in a root-owned secure path
(/Library/LaunchDaemons) — the system domain rejects plists in user-writable
locations such as /tmp, failing with `Bootstrap failed: 5: Input/output error`:

    cp -R build/Hostflip.app /Applications/
    sed -e 's|BundleProgram|Program|' \
        -e 's|Contents/MacOS/hostflipd|/Applications/Hostflip.app/Contents/MacOS/hostflipd|' \
        Packaging/com.heronapp.hostflip.daemon.plist > /tmp/com.heronapp.hostflip.daemon.plist
    sudo sh -c 'cp /tmp/com.heronapp.hostflip.daemon.plist /Library/LaunchDaemons/ &&
        chown root:wheel /Library/LaunchDaemons/com.heronapp.hostflip.daemon.plist &&
        chmod 644 /Library/LaunchDaemons/com.heronapp.hostflip.daemon.plist &&
        chown -R root:wheel /Applications/Hostflip.app &&
        launchctl bootstrap system /Library/LaunchDaemons/com.heronapp.hostflip.daemon.plist'

    /Applications/Hostflip.app/Contents/MacOS/Hostflip --handshake
    # expected: protocolVersion=1 daemonVersion=0.1.0

    /Applications/Hostflip.app/Contents/MacOS/Hostflip --status
    # SMAppService queries the system domain by Label: enabled while manually
    # loaded, notFound when not loaded

**CLI-identifier acceptance**: the daemon also accepts a client signed with
the CLI identifier `com.heronapp.hostflip.cli` (same Team ID). Until the
bundled CLI binary ships, verify by re-signing a copy of the app binary with
the CLI identifier and handshaking:

    cp /Applications/Hostflip.app/Contents/MacOS/Hostflip /tmp/Hostflip-cli-id
    codesign --force --options runtime --identifier com.heronapp.hostflip.cli \
        --sign "Developer ID Application: <Name> (<TEAMID>)" /tmp/Hostflip-cli-id
    /tmp/Hostflip-cli-id --handshake
    # expected: protocolVersion=1 daemonVersion=<version> — the CLI identifier
    # is inside the accepted pair, so the daemon keeps the connection

## 4. Negative verification (rejection in both directions)

- **Unsigned app**: on an ad-hoc build, `Hostflip --handshake` should fail
  immediately with `selfSigningUnavailable` — the app side fails closed and
  never initiates a connection.
- **Unsigned daemon**: running an ad-hoc built `hostflipd` directly should
  exit immediately (exit code 78) with a message about the unsigned build.
- **Daemon-side rejection** (while the step 3 load is active): copy the app
  binary out, re-sign it with the same certificate but an identifier outside
  the accepted app/CLI pair, then handshake; the daemon cuts the connection
  and the app side reports `interrupted`:

      cp /Applications/Hostflip.app/Contents/MacOS/Hostflip /tmp/Hostflip-wrong-id
      codesign --force --options runtime --identifier com.evil.hostflip \
          --sign "Developer ID Application: <Name> (<TEAMID>)" /tmp/Hostflip-wrong-id
      /tmp/Hostflip-wrong-id --handshake   # expected: handshake fails: interrupted, exit 1

- **Handshake interruption**: after the step 3 load, restart the daemon with
  `sudo launchctl kickstart -k system/com.heronapp.hostflip.daemon`; a
  `--handshake` issued right afterward reports `interrupted` if it gets cut
  off, and a retry succeeds — verifying that interruptions surface as a
  recoverable state.
- **App-side rejection**: stop the correct daemon first, then re-sign the
  daemon with the same certificate but a wrong identifier and load it from a
  root-owned path. The correct app must reject that daemon:

      cp /Applications/Hostflip.app/Contents/MacOS/hostflipd /tmp/hostflipd-wrong-id
      codesign --force --options runtime --identifier com.evil.hostflip.daemon \
          --sign "Developer ID Application: <Name> (<TEAMID>)" /tmp/hostflipd-wrong-id
      sed -e 's|BundleProgram|Program|' \
          -e 's|Contents/MacOS/hostflipd|/Library/PrivilegedHelperTools/hostflipd-wrong-id|' \
          Packaging/com.heronapp.hostflip.daemon.plist \
          > /tmp/com.heronapp.hostflip.wrong-daemon.plist
      sudo launchctl bootout system/com.heronapp.hostflip.daemon
      sudo install -o root -g wheel -m 755 /tmp/hostflipd-wrong-id \
          /Library/PrivilegedHelperTools/hostflipd-wrong-id
      sudo install -o root -g wheel -m 644 /tmp/com.heronapp.hostflip.wrong-daemon.plist \
          /Library/LaunchDaemons/com.heronapp.hostflip.daemon.plist
      sudo launchctl bootstrap system \
          /Library/LaunchDaemons/com.heronapp.hostflip.daemon.plist
      /Applications/Hostflip.app/Contents/MacOS/Hostflip --handshake
      # expected: handshake fails: peerRejected, exit 1

## 5. Cleanup

    sudo sh -c 'launchctl bootout system/com.heronapp.hostflip.daemon;
        rm -f /Library/LaunchDaemons/com.heronapp.hostflip.daemon.plist;
        rm -f /Library/PrivilegedHelperTools/hostflipd-wrong-id;
        rm -rf /Applications/Hostflip.app'
    rm -f /tmp/com.heronapp.hostflip.daemon.plist \
        /tmp/com.heronapp.hostflip.wrong-daemon.plist \
        /tmp/Hostflip-wrong-id /tmp/hostflipd-wrong-id /tmp/Hostflip-cli-id

## Verification log

2026-08-07, run on macOS 26 (arm64) with a Developer ID certificate: steps
1–3 all matched expectations (handshake round trip connected); in the
negative verification, the unsigned fail-closed behavior on both sides and
the daemon-side wrong-identifier rejection were both reproduced; the
"handshake interruption" item was not executed separately (error mapping is
covered by unit tests, and the daemon-side rejection path was observed in
practice to produce `interrupted`).

2026-08-14, after relaxing the daemon-side requirement to accept the app or
CLI identifier: steps 1–2 re-run with a Developer ID certificate — the daemon
prints the parenthesized alternation and the app's requirement is unchanged.
Requirement semantics checked offline with `codesign --verify -R=` against
the signed binaries: the app identifier and a copy re-signed with the CLI
identifier both satisfy the daemon's requirement; a third identifier (the
daemon binary) and a wrong Team ID paired with a matching identifier both
fail — confirming the alternation is parenthesized so the Team ID constraint
binds on every branch. The sudo-based channel round trip (steps 3–4) was not
re-run.

2026-08-07 (later the same day), follow-up test of the app-side rejection
path added in review: the correct app handshaking with a daemon signed by
the same certificate but a wrong identifier consistently reports
`peerRejected` (exit 1), matching expectations; the positive control (the
correct daemon) passed before the swap. With this, rejection in both
directions has been verified in practice.
