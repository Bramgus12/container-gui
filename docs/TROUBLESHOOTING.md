# Troubleshooting

## The install command fails

`scripts/install.sh` stops at the first problem and installs nothing when a
check fails.

- **Checksum mismatch.** The download did not match the checksum GitHub
  publishes for the release asset. Nothing is installed. Retry once in case the
  download was truncated, then open an issue with both checksums.
- **Signature verification failed.** The app in the disk image did not pass
  `codesign --verify --deep --strict`. Do not install it by hand; report it.
- **Container GUI is running.** Quit the app and run the command again. The
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

Confirm the quarantine attribute is gone:

```sh
xattr -r -l "/Applications/Container GUI.app" | grep com.apple.quarantine
```

No output means the app is not quarantined. If the attribute is present, run the
install command again, or remove it directly:

```sh
xattr -d -r com.apple.quarantine "/Applications/Container GUI.app"
```

A copy that was downloaded and unpacked in a browser is quarantined until this
attribute is removed or the app is approved in **System Settings → Privacy &
Security**.

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
  **System → Updates**. **Container GUI → Check for Updates…** still works on
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

Container GUI supports Apple Container `0.12.0` through versions earlier than
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
and container runs expose cancellation while active. Container GUI terminates
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
Networks, then retry the exact network deletion. Container GUI does not offer a
force-network-delete operation because the Apple Container CLI has none.

## Network lists or inspections fail after retrying

Confirm the service is healthy in System, then retry the Networks screen. If
cached rows remain visible, the error banner describes the most recent refresh
failure without discarding the last successful inventory. Copy sanitized
diagnostics from System when reporting persistent failures.
