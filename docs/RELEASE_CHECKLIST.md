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
- Confirm delete, force delete, image delete, and service stop show a
  descriptive confirmation and that Cancel preserves the resource.
- Inspect copied setup and system diagnostics plus displayed service logs using
  seeded secrets. Confirm environment values, credentials, bearer tokens,
  private keys, and URL userinfo are absent.

## Package and install

Create the current ad-hoc signed distribution:

```sh
./scripts/release.sh
```

The script archives with an ad-hoc signature, creates `Container-GUI.dmg`,
verifies the app signature with `codesign`, verifies the disk image, and prints
its SHA-256 checksum. Confirm the DMG contains both `Container GUI.app` and the
Applications shortcut. It does not use a Developer ID certificate, submit the
app to Apple's notary service, or staple a notarization ticket. Confirm the
README warning and installation instructions are present. Install the app from
the DMG on a second clean Mac, approve it through Privacy & Security, complete
onboarding, and repeat the lifecycle smoke test through the GUI.

## Release notes

- State the supported macOS and Apple Container CLI range.
- Link the command reference for the exact current tested CLI tag, not `main`.
- List known limitations from the README.
- Include upgrade and rollback instructions.
- Attach checksums for the distributed artifact.
