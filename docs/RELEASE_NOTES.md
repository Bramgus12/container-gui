# Container GUI 1.2.0

Install or upgrade with:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
```

Container GUI 1.2.0 adds complete volume and image-building workflows, built-in
update checks, and a redesigned interface with richer live container details.

## Changes

- Adds volume listing, search, inspection, creation, deletion, confirmed
  pruning, and named-volume mounts for new containers across Apple Container
  0.12 and 1.x.
- Adds a guided image builder with build arguments, labels, targets, platforms,
  cache controls, resource limits, pull behavior, and output options.
- Adds a verified one-command installer and in-app update checks with release
  notes, skipped-version support, and a copyable upgrade command.
- Introduces a consistent light and dark design system, sortable resource
  tables, live sidebar activity, and clearer status and usage displays.
- Improves container and image inspectors, live statistics, build/run dialogs,
  and log filtering and layout.
- Fixes live logs failing to remain connected and system disk usage decoding
  as zero with current Apple Container output.
- Fixes valid build, volume, and mount values being rejected in optimized SDK
  27 builds.

## Compatibility and validation

- macOS 26 or later on Apple-silicon Macs.
- Apple Container CLI `0.12.0` or later and earlier than `2.0.0`.
- Validated on Apple silicon with macOS 27.0 (build 26A5416b) and Apple
  Container CLI 1.2.2 on 19 August 2026. Compatibility fixtures also cover the
  0.12.0 and 1.x JSON formats used by the app.
- The exact tested CLI command reference is available at
  <https://github.com/apple/container/blob/1.2.2/docs/command-reference.md>.

## Upgrade and rollback

Re-run the install command above to upgrade in place. To roll back, pin a
previous release, for example:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash -s -- --version v1.1.0
```

## Known limitations

The app does not yet manage registry authentication, build secrets or SSH
forwarding, interactive terminals, import/export, DNS or kernel settings,
image/container pruning, or remote hosts.

The distributed DMG is ad-hoc signed and is not notarized. The installer
verifies its GitHub-published SHA-256 checksum and code signature before
installing it. See the README for manual installation and Gatekeeper guidance.

# Container GUI 1.1.0

Container GUI 1.1.0 adds network management and safer container and image
workflows.

## Changes

- Adds dependency-aware image deletion that confirms and removes dependent
  containers before deleting an image.
- Adds cancellation for active container runs while preserving the draft and
  refreshing authoritative container and image state.
- Adds first-class network list, search, inspection, creation, deletion, and
  confirmed pruning, including built-in network protection and sanitized
  failures.
- Adds repeatable Run Container network attachments with optional MAC address
  and MTU values, backed by the same cached network inventory.
- Supports both Apple Container 0.12 network JSON and the redesigned 1.x
  schema. Network creation exposes `--plugin-variant` on 0.12 and repeatable
  plugin `--option` values on 1.x.

## Compatibility

- macOS 26 or later on Apple-silicon Macs.
- Apple Container CLI `0.12.0` or later and earlier than `2.0.0`.

The distributed DMG is ad-hoc signed and is not notarized. Follow the README's
Privacy & Security installation instructions when macOS blocks the first
launch.

# Container GUI 1.0.2

Container GUI 1.0.2 improves the container log viewer.

## Changes

- Adds selectable, wrapped log output with stable logical line numbers.
- Preserves the viewport while reading older output and provides an explicit
  **Jump to Latest** action.
- Keeps retained logs bounded without splitting UTF-8 characters or resetting
  logical line numbering during a stream.
- Fixes native log text being hidden by the line-number ruler, including the
  leading characters of wrapped lines.
- Improves log-viewer behavior across light and dark appearances and during
  live window resizing.

## Compatibility

- macOS 26 or later on Apple-silicon Macs.
- Apple Container CLI `0.12.0` or later and earlier than `2.0.0`.

The distributed DMG is ad-hoc signed and is not notarized. Follow the README's
Privacy & Security installation instructions when macOS blocks the first
launch.

# Container GUI 1.0

Container GUI 1.0 provides a native macOS interface for Apple Container on
Apple silicon.

## Highlights

- Guided preflight and onboarding for missing, unsupported, or stopped Apple
  Container installations.
- Container list, search, run, start, stop, normal delete, and force delete.
- Container overview, formatted inspection JSON, bounded/followed logs, and
  on-demand resource statistics.
- Image list, inspection, pull progress and cancellation, run-from-image, and
  confirmed deletion.
- Service health, start and confirmed stop, disk usage, bounded recent logs,
  and sanitized support diagnostics.

## Compatibility

- macOS 26 or later on Apple-silicon Macs.
- Apple Container CLI `0.12.0` or later and earlier than `2.0.0`.

The final distributed build must list the exact minimum and current CLI patch
versions exercised on clean Macs in its published release notes.

## Security and reliability

Commands are executed directly without a shell. Inputs are validated and
passed as discrete arguments. Long-running processes support cancellation,
retained output is bounded, destructive operations require confirmation, and
diagnostics redact common credential formats without including the process
environment.

## Known limitations

Version 1 does not manage volumes, builds, registry authentication,
interactive terminals, import/export, DNS, kernel settings, image/container
prune operations, or remote hosts. Compatibility with a new major Apple Container CLI version is
disabled until its JSON formats have been tested.
