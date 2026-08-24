# Container GUI 1.4.0

Install or upgrade with:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
```

Container GUI 1.4.0 closes the gap between what the Apple Container CLI can do
to a container and what the app can. Creating without starting, signalling,
pruning, running a command inside a container, copying files in and out, and
exporting a filesystem are all reachable from the containers screen.

## Changes

- Creates a container without starting it. The run sheet gains a **Run** /
  **Create** control; the action button and the command preview follow it.
  Nothing is started, so there is no progress to stream and nothing to detach
  from — the sheet closes as soon as the new container is created and selects
  it.
- Sends a signal to a running container. **Send Signal** on the More Actions and
  row menus offers an allowlist of signals rather than a free-text field.
  SIGKILL is confirmed first because the process gets no chance to shut down;
  signals a process can handle are sent without a prompt.
- Prunes stopped containers from a toolbar button, with a confirmation before
  anything is deleted and a summary of what was removed. Pruning deletes
  containers the app did not name, so it waits until no per-container operation
  is in flight and blocks new ones while it runs.
- Runs a one-off command inside a running container and shows what it printed,
  with environment variables, user, and working directory. The process gets no
  terminal, which suits what a GUI is good for; **Open in Terminal** hands the
  interactive form of the same command to Terminal.app for anything that expects
  to be typed at.
- Copies files between a container and the local filesystem in either direction,
  with a file panel for the host side.
- Exports a container's filesystem as a tar archive, choosing the destination in
  a save panel so an existing file is never overwritten silently, and reporting
  progress for a write that can take a while. A container that is still running
  is exported as a snapshot of a filesystem being written to, and the sheet says
  so rather than refusing.

## Compatibility and validation

- macOS 26 or later on Apple-silicon Macs.
- Apple Container CLI `0.12.0` or later and earlier than `2.0.0`.
- Flag names for every new command were checked against `container <command>
  --help` from CLI `1.2.2`: `create` takes the run flags without `--progress`,
  `kill` takes `--signal`, `export` takes `--output`, and `copy` is the
  canonical spelling of `cp`.
- The full unit and UI suites pass (309 unit tests, 20 UI tests). The manual
  gates in `docs/RELEASE_CHECKLIST.md` have not been run for this release, and
  the notarization and download-verification details below are recorded when the
  release is cut.

## Known limitations

Interactive terminals still run in Terminal.app rather than inside the app. The
pseudo-terminal plumbing exists and is tested, but no terminal view is wired to
it. The app does not yet manage registry authentication, build secrets or SSH
forwarding, import, or kernel settings, or remote hosts.

# Container GUI 1.3.0

Install or upgrade with:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
```

Container GUI 1.3.0 finishes the local DNS setup. Both halves of it — the
resolver entry that needs root and the service domain in your own
`config.toml` — are now changes the app makes for you, instead of commands and
snippets it asks you to run and paste yourself.

## Changes

- Adds and removes local DNS domains directly. Writing to `/etc/resolver` needs
  root, so the app raises the standard macOS authentication dialog, naming the
  domain it is about to change, and runs the command through the Security Agent
  once you authenticate. Dismissing the dialog cancels the change and reports
  nothing as having happened.
- Sets the service DNS domain in `~/.config/container/config.toml`. The file is
  yours, so this needs no administrator access. The edit is surgical: it
  rewrites the one `domain` line under `[dns]` and copies every other setting,
  comment, and blank line through unchanged, so a `domain` key in another table
  is left alone. A file that states its DNS settings as an inline table or an
  array of tables is reported as uneditable rather than rewritten.
- Detects when a written domain is not yet in force. The service reads its DNS
  domain when it starts, so the app compares what it wrote against what the
  service reports; when they differ, the DNS section shows a restart notice with
  a **Restart Service** button, and the notice clears itself once the service
  reports the new domain.
- Keeps every manual path. **Copy Command**, **Copy TOML**, and **Reveal Config**
  remain wherever the app can now make the change itself.

## Compatibility and validation

- macOS 26 or later on Apple-silicon Macs.
- Apple Container CLI `0.12.0` or later and earlier than `2.0.0`.
- The app installs no privileged helper and holds no standing elevated rights.
  Each `/etc/resolver` change is authorised on its own through macOS.
- Built from commit `76be378` on Apple silicon with macOS 27.0 and Apple
  Container CLI `1.2.2` on 23 August 2026. Apple's notary service accepted both
  the app and the disk image; `spctl --assess` reports `accepted` with
  `source=Notarized Developer ID` for each, and the app still validates after
  being copied out of the disk image.
- The full unit and UI suites pass (227 unit tests, 17 UI tests). The manual
  gates in `docs/RELEASE_CHECKLIST.md` — VoiceOver, the real smoke test, and the
  clean-Mac download test — have not been run for this release, and the macOS
  authentication dialog has not been exercised end to end.

## Download verification

SHA-256: `7a88bb5c55dfa4848d810b35778c800daac08505bf6b03da1633398b50f477ac`

The disk image is signed with a Developer ID Application certificate and
notarized by Apple. Verify an installed copy yourself with:

```sh
spctl --assess --type execute --verbose=4 "/Applications/Container GUI.app"
```

## Upgrade and rollback

Re-run the install command above to upgrade in place. To roll back, pin a
previous release, for example:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash -s -- --version v1.2.1
```

Releases up to and including 1.2.0 are ad-hoc signed and not notarized, so
rolling back to one restores the Gatekeeper approval steps described in their
release notes.

## Known limitations

The app does not yet manage registry authentication, build secrets or SSH
forwarding, interactive terminals, import/export, or kernel settings,
image/container pruning, or remote hosts.

# Container GUI 1.2.1

Install or upgrade with:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
```

Container GUI 1.2.1 is the first release signed with a Developer ID certificate
and notarized by Apple. The application code is unchanged from 1.2.0.

## Changes

- Signs the app and the disk image with a Developer ID Application certificate,
  notarizes both with Apple, and staples the tickets to each. macOS now accepts
  the app on first launch with no Privacy & Security approval, and the check
  works offline.
- Rewrites `scripts/release.sh` to run the whole signing, notarization, and
  stapling pipeline, verifying the Hardened Runtime, the secure timestamp, and
  the Gatekeeper assessment of both artifacts before it reports success.

## Compatibility and validation

- macOS 26 or later on Apple-silicon Macs.
- Apple Container CLI `0.12.0` or later and earlier than `2.0.0`.
- Apple's notary service accepted both the app and the disk image. Verified on
  Apple silicon with macOS 27.0 on 23 August 2026 that `spctl --assess` reports
  `accepted` with `source=Notarized Developer ID` for the app and the image, and
  that the app still carries a valid stapled ticket after being copied out of
  the disk image.
- Runtime behavior carries over from the 1.2.0 validation, since no application
  code changed in this release.

## Download verification

SHA-256: `7f38c8e161880eac0dd0d83b34d414721751f66cb76dc4872602ef084be36afd`

The disk image is signed with a Developer ID Application certificate and
notarized by Apple. Verify an installed copy yourself with:

```sh
spctl --assess --type execute --verbose=4 "/Applications/Container GUI.app"
```

## Upgrade and rollback

Re-run the install command above to upgrade in place. To roll back, pin a
previous release, for example:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash -s -- --version v1.2.0
```

Releases up to and including 1.2.0 are ad-hoc signed and not notarized, so
rolling back to one restores the Gatekeeper approval steps described in their
release notes.

## Known limitations

The app does not yet manage registry authentication, build secrets or SSH
forwarding, interactive terminals, import/export, or kernel settings,
image/container pruning, or remote hosts.

# Container GUI 1.2.0

Install or upgrade with:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
```

Container GUI 1.2.0 adds complete volume and image-building workflows, built-in
update checks, and a redesigned interface with richer live container details.

## Changes

- Adds DNS readiness and local-domain management to System, including resolver
  inspection, system-resolution probes, copyable administrator commands, and
  per-container DNS options in the Run Container sheet.
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
forwarding, interactive terminals, import/export, or kernel settings,
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
