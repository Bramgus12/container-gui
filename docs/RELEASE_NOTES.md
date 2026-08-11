# Unreleased

## Changes

- Adds dependency-aware image deletion that confirms and removes dependent
  containers before deleting an image.
- Adds cancellation for active container runs while preserving the draft and
  refreshing authoritative container and image state.

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

Version 1 does not manage networks, volumes, builds, registry authentication,
interactive terminals, import/export, DNS, kernel settings, prune operations,
or remote hosts. Compatibility with a new major Apple Container CLI version is
disabled until its JSON formats have been tested.
