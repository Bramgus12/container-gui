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
or remote hosts. Image deletion can fail while a container depends on the
image. Compatibility with a new major Apple Container CLI version is disabled
until its JSON formats have been tested.
