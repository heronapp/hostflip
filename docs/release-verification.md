# Release process verification

`scripts/release.sh` is the local release pipeline (M5 #27): guards → clean build + signing →
signature acceptance → notarization + staple → DMG → Gatekeeper acceptance → GitHub Release.
This document records the one-time setup, the rehearsal/release steps, and the verification log.

## One-time setup

1. The Keychain contains a "Developer ID Application" certificate for Team `EA9SPTEHTA`
   (visible via `security find-identity -v -p codesigning`).
2. Store the notarytool credentials in the keychain (from then on the pipeline refers to
   them only by profile name and never touches the secrets):

       xcrun notarytool store-credentials hostflip-notary \
           --apple-id <AppleID> --team-id EA9SPTEHTA

   If another profile for the same Team already exists, it can be used via
   `NOTARY_PROFILE=<name>` — no need to store credentials again.
3. `gh auth status` is logged in (only required for a full release).

## Rehearsal (does not touch GitHub)

    scripts/release.sh --no-publish

Expected: all guards pass → build and sign → per-object acceptance checks (TeamIdentifier /
secure timestamp / hardened runtime / daemon identifier) → notarization #1 Accepted,
staple app + validate, `spctl --type execute` passes → DMG signed, notarization #2
Accepted, staple + validate, `spctl --type open` passes → produces
`build/dist/Hostflip-<version>.dmg`.

## Full release

    scripts/release.sh

On top of the rehearsal, this requires the local HEAD to already be pushed to origin/main.
At the end it creates the GitHub Release as a draft (tag `v<version>`) and uploads the DMG,
publishing only once everything is ready — any failure before publish leaves no
publicly visible half-finished release; a same-named draft left over from a previous
failed run (not externally visible) is cleaned up at the start of the next run.

## Negative guard verification

Each case was triggered one by one in a temporary clone (with origin pointing at a local
bare mirror); all of them were blocked with exit 1 as expected and produced no artifacts:

| Scenario | Expected error |
| --- | --- |
| Unknown argument | unknown argument |
| Dirty tree (including untracked files) | git tree is not clean |
| Version `0.1` | not an X.Y.Z semantic version |
| plist disagrees with `HostflipBuild.version` | the two locations disagree |
| CFBundleVersion `0` | not a positive integer |
| Same-named tag already exists on the remote | tag already exists on origin |
| CFBundleVersion not higher than the previous release tag | build version not higher |
| HEAD not pushed in publish mode | local HEAD does not match origin/main |

With a valid version and a properly incremented build number, all of the version guards
above let the run through (evidenced by reaching the HEAD check in publish mode).

## Verification log

Executed on 2026-08-11 on macOS 26 (arm64) with the Developer ID certificate: all 8
negative scenarios in the table above were reproduced; with `NOTARY_PROFILE` pointing to
an existing profile of the same Team, `scripts/release.sh --no-publish` completed the full
rehearsal (both notarization rounds Accepted; both the app and the DMG were
stapled + validated and passed spctl), producing `build/dist/Hostflip-0.1.0.dmg`.
The one-time store-credentials step for the default profile `hostflip-notary` was not
executed on this machine (the credentials are the user's secret); the mechanism is
identical to the profile actually used in the test. The full release (the GitHub Release
stage) is left for the actual v0.1.0 release (#28); the flags of every gh subcommand were
verified against `--help`.

Two shell pitfalls were found and fixed: in an expansion like `"$VER」"` — a variable
immediately followed by a full-width character — macOS bash 3.2 absorbs the bytes of the
multi-byte character into the variable name (reporting unbound variable), so all such
expansions are written in the braced form `${VER}`; piping `codesign -dvv |
grep -q` directly makes codesign receive SIGPIPE when grep exits early, which under
pipefail is misreported as a failure — changed to capture the output into a variable
first, then grep.
