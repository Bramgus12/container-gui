# Troubleshooting

## The install command fails

`scripts/install.sh` stops at the first problem and installs nothing when a
check fails.

- **Checksum mismatch.** The download did not match the checksum GitHub
  publishes for the release asset. Nothing is installed. Retry once in case the
  download was truncated, then open an issue with both checksums.
- **Signature verification failed.** The app in the disk image did not pass
  `codesign --verify --deep --strict`. Do not install it by hand; report it.
- **CargoDeck is running.** Quit the app and run the command again. The
  installer never replaces a running app.
- **The GitHub API is unavailable or rate-limited.** Unauthenticated API calls
  are limited to 60 per hour per address. The installer falls back to the latest
  release link and prints the downloaded checksum, which you can compare with
  the release notes yourself. Pin a release with `--version` to skip the lookup
  of the newest tag.
- **`/Applications` is not writable.** The installer asks for an administrator
  password when it runs in a terminal, and otherwise installs into
  `~/Applications`. Use `--user` to choose that explicitly.
- **Wrong platform.** The installer applies the same rules as the app: an
  Apple-silicon Mac running macOS 26 or later.

## macOS still blocks the app after installing

Releases from 1.2.1 onward are signed with a Developer ID Application
certificate and notarized by Apple, with the ticket stapled to both the app and
the disk image, so Gatekeeper should accept them without any approval step, even
offline. If macOS blocks the app anyway, check what Gatekeeper actually objects
to:

```sh
spctl --assess --type execute --verbose=4 "/Applications/CargoDeck.app"
xcrun stapler validate "/Applications/CargoDeck.app"
codesign --verify --deep --strict --verbose=2 "/Applications/CargoDeck.app"
```

`accepted` with `source=Notarized Developer ID` means the installed copy is
sound and the problem lies elsewhere. Anything else means the copy is damaged or
was modified after signing: delete it and install again, comparing the DMG
checksum with the release notes. Do not work around a failing signature by
approving the app in **System Settings → Privacy & Security**.

Releases up to and including 1.2.0 were ad-hoc signed and not notarized. Those
older builds rely on the quarantine attribute being cleared:

```sh
xattr -d -r com.apple.quarantine "/Applications/CargoDeck.app"
```

## The update check fails

**System → Updates** reports why, and a failed check never changes the app.

- **GitHub is rate-limiting update checks.** Unauthenticated GitHub API requests
  are limited to 60 per hour per address. The app checks at most once a day, so
  this usually means something else on the network shares the limit. Wait and
  use **Check Now**.
- **The update check could not reach GitHub.** The machine is offline or a proxy
  blocks `api.github.com`. Update checks are the only network requests Container
  GUI makes; every container operation runs locally through the CLI.
- **Turning it off.** Clear **Check automatically once a day** under
  **System → Updates**. **CargoDeck → Check for Updates…** still works on
  demand.
- **A skipped version.** **Skip This Version** hides one release from the
  automatic check. The Updates section then offers **Show Again**, and a manual
  check always reports the truth.

## The container executable is missing

Install Apple Container from its official release package. If it is installed
outside `/usr/local/bin/container` or `/opt/homebrew/bin/container`, choose the
executable in onboarding. The selected file must be an absolute, regular,
executable file.

## The CLI version is unsupported

CargoDeck supports Apple Container `0.12.0` through versions earlier than
`2.0.0`. Install a supported release or select a compatible executable. Support
for a newer CLI is added only after its JSON output has fixture and smoke-test
coverage.

## The service is stopped or unavailable

Use **Start Service** in onboarding or the System screen. If starting fails,
run `container system status --format json` in Terminal and review the System
screen's recent logs. Service stop requires confirmation because it stops
running containers.

## Lists fail after a CLI upgrade

Confirm that the upgraded version is in the supported range. If it is, open
**System → Diagnostics**, copy the sanitized report, and include it with the
exact CLI version in a bug report. Diagnostics exclude process environment
values and redact common secret, token, password, credential, authorization,
private-key, and URL-userinfo patterns.

## Pulls or commands hang

Cancel the operation and retry after checking network connectivity. Image pulls
and container runs expose cancellation while active. CargoDeck terminates
cancelled child processes, refreshes authoritative state because cancellation
cannot undo completed container creation, and caps retained command and log
output. If the service remains unhealthy, restart it outside any active
container workload.

## A container or image cannot be deleted

Refresh first. A normal container delete requires it to be stopped; force
delete is available with a separate confirmation. When containers depend on an
image, image deletion lists them and can delete them before deleting the image.
Running containers are force deleted. Cleanup is not transactional: if one
deletion fails, earlier deletions remain applied and the image is preserved.

## A network cannot be created

Check that the name uses 1–63 lowercase letters, digits, dots, underscores, or
hyphens and starts and ends with a letter or digit. IPv4 prefixes must be
between 0 and 32; IPv6 prefixes must be between 0 and 128. The CLI can also
reject otherwise valid CIDRs when they overlap an existing network. Refresh the
Networks screen, choose non-overlapping subnets, and retry.

## A network cannot be deleted

Built-in and default networks are intentionally protected. For a user-created
network, stop and delete any containers attached to it, refresh Containers and
Networks, then retry the exact network deletion. CargoDeck does not offer a
force-network-delete operation because the Apple Container CLI has none.

## Network lists or inspections fail after retrying

Confirm the service is healthy in System, then retry the Networks screen. If
cached rows remain visible, the error banner describes the most recent refresh
failure without discarding the last successful inventory. Copy sanitized
diagnostics from System when reporting persistent failures.

## Registry login fails

Check the **Server** field first: it takes a host, optionally with a port —
`ghcr.io`, `localhost:5000` — and not a URL. A pasted `https://ghcr.io` is
rejected in the sheet before it reaches the CLI, and the transport is chosen
with the **Scheme** control instead.

If the server and user name are right, the failure is the registry's answer,
not the app's. Confirm the credential is the one that registry expects: many
require a personal access token rather than an account password, and some need
a specific user name alongside a token.

CargoDeck never stores the password. It is written to the command's
standard input and released, so a failed login leaves nothing to clear, and
retrying means typing it again.

## Automatic, HTTPS, or HTTP for a registry

**Automatic** sends no `--scheme` flag and lets the CLI apply its own default.
This is deliberate: Apple Container 0.12–1.0 accepted `auto` and defaulted to
it, while 1.3.1 accepts only `http` and `https` and defaults to `https`. Sending
`auto` would fail outright on current releases, so the app never sends it.

Choose **HTTPS** to require an encrypted connection. Choose **HTTP** only for a
registry on a network you control: the user name, the password, and the image
layers all travel in the clear, and the sheet says so before you submit.

## A push was cancelled part-way

Cancelling stops the local process. It does not roll the remote registry back,
and CargoDeck does not claim that it does. A cancelled push may have
uploaded some layers, and may or may not have updated the tag. Check the
registry itself before pushing again.

The same caution applies to a cancelled **Load**: some images from the archive
may already have been imported, which is why the image list refreshes after a
cancellation as well as after a success.

## An image archive cannot be saved or loaded

**Save** needs an absolute path and replaces any existing file there. Use
**Choose…** to pick the destination if the path is being rejected; the field
requires a full path rather than a name relative to your home folder.

**Load** reads an OCI-compatible tar archive written by `container image save`.
It is not a Docker `docker save` archive and not a container filesystem export.
The **Load archives with invalid member files** option maps to the CLI's
`--force`, which accepts an archive whose members do not all validate — it does
not bypass other import failures.

## Images will not delete in bulk

Bulk deletion never removes containers. An image a container still uses is
listed as blocked in the confirmation and preserved by the CLI, so the delete
reports a partial failure rather than cascading into container deletion.

Delete those containers first, or use the single-image **Delete** action, which
plans the dependent-container cleanup and asks before doing it.

**Ignore targets that are already missing** is the CLI's `--force`, and it only
suppresses not-found errors. There is no force-remove-in-use-images option in
the CLI and none in the app.

## Pruning removed more or less than expected

The candidate count in the prune sheet is an estimate from the image and
container lists the app can see. Reachability is the CLI's decision, so the
result can differ. **Dangling images only** maps to `container image prune`;
**All images no container uses** maps to `container image prune --all` and will
remove tagged images too. System → **Reclaim** remains the combined image and
volume shortcut.

## Registry credentials in diagnostics

Passwords and tokens are never written to a command, a command preview, the
failure log, copied diagnostics, or an error message — the secret reaches the
CLI only through the child process's standard input. If you believe one has
appeared in an artifact, that is a bug worth reporting with the artifact
attached.
