# Release checklist

Use this checklist for every v1 release candidate. Record the tested macOS,
hardware, CLI version, app commit, tester, and date in the release notes.

## Automated gates

- Run the `Container GUI` Xcode scheme tests in Debug, then run the optimized
  Release test build with `scripts/test-release.sh`. The script uses ad-hoc
  signing and disables Hardened Runtime only for the test host so its XCTest
  bundles can load without a Team ID; release archives remain hardened.
- Confirm onboarding and lifecycle UI tests pass with the fake CLI.
- Run `scripts/real-smoke-test.sh` on clean Apple-silicon Macs with CLI `0.12.0`
  and the current supported CLI release.
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
the ticket, builds and signs `Container-GUI.dmg`, notarizes and staples the disk
image too, runs the Gatekeeper assessment on both, and prints the SHA-256
checksum. A Developer ID Application certificate and stored notary credentials
are prerequisites; see the build section of the README.

- Confirm the DMG contains both `Container GUI.app` and the Applications
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

After the release and its `Container-GUI.dmg` asset are published, verify the
one-command installer against it on a clean Apple-silicon Mac:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
```

- Confirm the printed SHA-256 matches the checksum in the release notes and that
  the installer reports the expected release tag.
- Confirm the app opens with no Gatekeeper dialog, and that
  `spctl --assess --type execute --verbose=4 "/Applications/Container GUI.app"`
  reports `accepted` with `source=Notarized Developer ID`.
- Re-run the command over the existing install and confirm it upgrades in place.
- Confirm `--version <previous tag>`, `--user`, and `--uninstall` each behave,
  and that `--uninstall` leaves settings at
  `~/Library/Preferences/com.gussekloo.container-gui.plist`.
- Confirm a failed run leaves no mounted disk image behind (`hdiutil info`).

Then confirm the in-app update check sees the new release. Launch the previous
version and open **System → Updates**: it must report the new version, its
notes, and a working **Copy Install Command**. Confirm the new version reports
up to date, that **Skip This Version** hides only the automatic result, and that
`container-gui-tests/Fixtures/github/release-latest.json` still matches the
shape GitHub returns for the release.

## Release notes

- Lead with the one-command install line so it appears in the release body.
- State the supported macOS and Apple Container CLI range.
- Link the command reference for the exact current tested CLI tag, not `main`.
- List known limitations from the README.
- Include upgrade and rollback instructions.
- Attach checksums for the distributed artifact.
