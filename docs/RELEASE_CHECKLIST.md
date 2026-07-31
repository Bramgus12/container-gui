# Release checklist

Use this checklist for every v1 release candidate. Record the tested macOS,
hardware, CLI version, app commit, tester, and date in the release notes.

## Automated gates

- Run the `Container GUI` Xcode scheme tests in Debug and Release.
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
- Confirm delete, force delete, image delete, and service stop show a
  descriptive confirmation and that Cancel preserves the resource.
- Inspect copied setup and system diagnostics plus displayed service logs using
  seeded secrets. Confirm environment values, credentials, bearer tokens,
  private keys, and URL userinfo are absent.

## Sign, notarize, and install

Store notary credentials in a keychain profile:

```sh
xcrun notarytool store-credentials container-gui-notary
```

Then run:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
NOTARYTOOL_PROFILE=container-gui-notary \
./scripts/release.sh
```

The script archives, exports with Developer ID, submits to notarytool, staples,
and verifies with `codesign`, `stapler`, and Gatekeeper. Install the exported app
on a second clean Mac, launch it from Finder, complete onboarding, and repeat
the lifecycle smoke test through the GUI.

## Release notes

- State the supported macOS and Apple Container CLI range.
- Link the command reference for the exact current tested CLI tag, not `main`.
- List known limitations from the README.
- Include upgrade and rollback instructions.
- Attach checksums for the distributed artifact.
