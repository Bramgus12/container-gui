# Troubleshooting

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
