# Release checklist

Use this checklist for every v1 release candidate. Record the tested macOS,
hardware, CLI version, app commit, tester, and date in the release notes.

## Automated gates

- Run the `CargoDeck` Xcode scheme tests in Debug, then run the optimized
  Release test build with `scripts/test-release.sh`. The script uses ad-hoc
  signing and disables Hardened Runtime only for the test host so its XCTest
  bundles can load without a Team ID; release archives remain hardened.
- Confirm onboarding and lifecycle UI tests pass with the fake CLI.
- Run `scripts/real-smoke-test.sh` on clean Apple-silicon Macs with CLI `0.12.3`
  and the current supported CLI release.
- Run the opt-in registry checklist in `docs/RELEASE_CHECKLIST.md` §Registry
  against a disposable registry. Never run it against a registry whose login
  you cannot restore.
- Repeat the real smoke test with slow or unavailable networking and confirm
  cancellation leaves no test container behind.
- Run static analysis and build with warnings treated as errors.

## Compatibility and failure injection

- Verify missing executable and stopped-service onboarding.
- Exercise nonzero exits, corrupt/truncated JSON, unknown fields and states,
  oversized output, simultaneous stdout/stderr, slow streams, cancellation,
  timeouts, and network loss.
- Upgrade the CLI while the app is closed, relaunch, and confirm preflight
  accepts or rejects the exact version clearly.
- Never add a supported CLI version without representative container, image,
  version, status, inspect, and stats fixtures.

## Registry

Opt-in, run manually against a **disposable** registry only. These steps mutate
stored credentials or a remote repository, so they are deliberately absent from
`scripts/real-smoke-test.sh`.

- Do not start unless you can restore whatever login the machine already holds.
  `container registry list --quiet` first, and note what is there. Logging in to
  a host that already has a login overwrites it with no way back.
- Use a repository and tag that exist for this test alone, on a registry you
  control. Never push to a shared or production repository.
- Log in from the Registries screen with an explicit user name and a token, and
  confirm the host appears in the list. Confirm the command strip ends in
  `--password-stdin` and shows no password and no placeholder for one.
- Repeat the login with the scheme set to HTTP and confirm the sheet shows the
  unencrypted-transport warning and still emits `--scheme http`, not `auto`.
- Tag a throwaway image for that registry, push it, and confirm the push is
  cancellable. After a cancelled push, verify the remote state yourself — the
  app reports an interrupted push and does not claim a rollback.
- Log out and confirm the host leaves the list and that a subsequent private
  pull fails as expected.
- Restore the machine's original logins.
- Search the copied diagnostics, the failure log, the command previews, any
  screenshots taken, and the UI hierarchy for the seeded token. It must appear
  in none of them.

## Accessibility and safety

- Test every screen using VoiceOver without a pointer.
- Traverse all controls with Tab and Shift-Tab; verify visible, logical focus.
- Test Increase Contrast, Reduce Motion, and the largest supported text size.
- Verify status is conveyed by labels and symbols, not color alone.
- Confirm delete, force delete, dependency-aware image cleanup, and service stop
  show a descriptive confirmation and that Cancel preserves every resource.
- Cancel an active container run and verify its draft remains available, its
  child process terminates, and container/image state refreshes afterward.
- Inspect copied setup and system diagnostics plus displayed service logs using
  seeded secrets. Confirm environment values, credentials, bearer tokens,
  private keys, and URL userinfo are absent.

## Package and install

Create the signed, notarized distribution:

```sh
./scripts/release.sh
```

The script archives with the Developer ID Application certificate and the
Hardened Runtime, exports it, submits the app to Apple's notary service, staples
the ticket, builds and signs `CargoDeck.dmg`, notarizes and staples the disk
image too, runs the Gatekeeper assessment on both, and prints the SHA-256
checksum. A Developer ID Application certificate and stored notary credentials
are prerequisites; see the build section of the README.

- Confirm the DMG contains both `CargoDeck.app` and the Applications
  shortcut.
- Confirm the run printed `accepted` with `source=Notarized Developer ID` for
  the app and the disk image.
- Confirm `xcrun stapler validate` passes on both artifacts, and that the app
  still validates after being copied out of the DMG.
- Download the published DMG in a browser on a second clean Mac and confirm it
  opens with no Gatekeeper dialog and no Privacy & Security approval, then
  complete onboarding and repeat the lifecycle smoke test through the GUI.
- Confirm the notarization holds offline: disable networking on that Mac and
  launch the app again.

After the release and its `CargoDeck.dmg` asset are published, verify the
one-command installer against it on a clean Apple-silicon Mac:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/CargoDeck/main/scripts/install.sh | bash
```

- Confirm the printed SHA-256 matches the checksum in the release notes and that
  the installer reports the expected release tag.
- Confirm the app opens with no Gatekeeper dialog, and that
  `spctl --assess --type execute --verbose=4 "/Applications/CargoDeck.app"`
  reports `accepted` with `source=Notarized Developer ID`.
- Re-run the command over the existing install and confirm it upgrades in place.
- Confirm `--version <previous tag>`, `--user`, and `--uninstall` each behave,
  and that `--uninstall` leaves settings at
  `~/Library/Preferences/com.gussekloo.CargoDeck.plist`.
- Confirm a failed run leaves no mounted disk image behind (`hdiutil info`).

Then confirm the in-app update check sees the new release. Launch the previous
version and open **System → Updates**: it must report the new version, its
notes, and a working **Copy Install Command**. Confirm the new version reports
up to date, that **Skip This Version** hides only the automatic result, and that
`CargoDeckTests/Fixtures/github/release-latest.json` still matches the
shape GitHub returns for the release.

## Release notes

- Lead with the one-command install line so it appears in the release body.
- State the supported macOS and Apple Container CLI range.
- Link the command reference for the exact current tested CLI tag, not `main`.
- List known limitations from the README.
- Include upgrade and rollback instructions.
- Attach checksums for the distributed artifact.
