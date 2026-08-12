<div align="center">

<img src="docs/app-icon.png" alt="Container GUI app icon" width="160">

# Container GUI

### Apple Container, without the command-line friction.

A native macOS control center for running containers, managing images,
watching resource usage, and keeping the Apple Container service healthy.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-111111?style=for-the-badge&logo=apple&logoColor=white)](#requirements)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Apple Container 0.12–<2.0](https://img.shields.io/badge/Apple%20Container-0.12–%3C2.0-3276D3?style=for-the-badge&logo=docker&logoColor=white)](https://github.com/apple/container)

[Get started](#getting-started) · [Explore features](#everything-you-need-in-one-window) · [Develop](#development) · [Troubleshoot](docs/TROUBLESHOOTING.md)

</div>

---

Container GUI wraps Apple's [`container`](https://github.com/apple/container)
CLI in a focused SwiftUI experience. It handles the everyday container
workflow—from guided setup to logs and live statistics—while executing commands
directly, never through a shell.

## Everything you need in one window

| | Capability | What you can do |
| :---: | --- | --- |
| 📦 | **Containers** | Search, filter, run, start, stop, and safely delete containers. |
| 🔎 | **Deep inspection** | Explore structured container configuration, networking, ports, mounts, image variants, and OCI metadata. |
| 📜 | **Logs & stats** | Follow bounded logs and monitor CPU, memory, network, and block I/O. |
| 🖼️ | **Images** | Search local images, inspect metadata, stream pull progress, run, and delete with dependency-aware cleanup. |
| 🌐 | **Networks** | List, search, inspect, create, delete, and prune networks, with Apple Container 0.12 and 1.x compatibility. |
| 🔗 | **Container networking** | Attach a new container to multiple networks with optional MAC addresses and MTUs. |
| ❤️ | **System health** | Check CLI and server versions, control the service, and review disk usage and recent logs. |
| ⬆️ | **Update checks** | See when a newer Container GUI release exists, read its notes, and copy the upgrade command. |
| 🩺 | **Diagnostics** | Copy a sanitized support report with common secrets and credentials redacted. |

### Designed to feel at home on macOS

- A native `NavigationSplitView`, searchable tables, inspectors, sheets, and
  familiar keyboard shortcuts.
- Guided onboarding for a missing executable, incompatible CLI, or stopped
  background service.
- Context-aware actions that disable invalid operations and prevent conflicting
  work on the same resource.
- Clear progress, cancellation, empty states, and actionable error messages
  throughout the app.

## Getting started

### 1. Check the requirements

- An **Apple-silicon Mac** running **macOS 26 or later**
- [Apple Container](https://github.com/apple/container/releases) CLI version
  **0.12.0 or later and earlier than 2.0.0**
- Xcode, when building Container GUI from source

### 2. Install Apple Container

Download Apple Container from its
[official releases](https://github.com/apple/container/releases) and complete
its installation. Container GUI normally discovers the executable at
`/usr/local/bin/container` or `/opt/homebrew/bin/container`; you can also choose
a custom executable during onboarding.

### 3. Install Container GUI

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh | bash
```

The installer downloads the latest release disk image, checks its SHA-256
against the checksum GitHub publishes for the release asset, verifies the app's
code signature, installs it into `/Applications`, and removes the
`com.apple.quarantine` attribute so macOS does not block the first launch.

To read the script before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/container-gui/main/scripts/install.sh -o install.sh
```

Then review `install.sh` and run `bash install.sh`.

Useful options: `--version v1.1.0` pins a release, `--user` installs into
`~/Applications` and never asks for an administrator password, `--dir <path>`
chooses another location, and `--uninstall` removes the app while keeping its
settings. Re-running the command upgrades an existing installation in place.

On first launch, the app verifies the platform, executable, CLI version, and
service health before opening the main interface. If the service is installed
but stopped, it can be started directly from onboarding.

Once a day the app asks GitHub whether a newer release exists and shows the
result under **System → Updates**, where the check can also be run on demand or
turned off entirely. **Container GUI → Check for Updates…** checks immediately.
Updating is always the same one-line command as installing.

> [!WARNING]
> Container GUI releases are currently ad-hoc signed and **not notarized by
> Apple**. Apple cannot verify the developer identity or confirm that the app
> passed its automated malware scan. The installer clears Gatekeeper's
> quarantine flag for this one app, which is why it opens without the approval
> steps below. Only continue if you trust this project and understand the risk.

### Installing from the DMG by hand

Download `Container-GUI.dmg` from the
[releases page](https://github.com/Bramgus12/container-gui/releases) and compare
its SHA-256 with the checksum in the release notes:

```sh
shasum -a 256 ~/Downloads/Container-GUI.dmg
```

Because the app is not Developer ID signed or notarized, Gatekeeper prevents a
browser-downloaded copy from opening. To approve this specific app without
disabling Gatekeeper globally:

1. Move **Container GUI.app** to the Applications folder and try to open it.
2. Open **System Settings**, select **Privacy & Security**, and scroll to
   **Security**.
3. Click **Open Anyway** for Container GUI, authenticate, and confirm **Open**.

The **Open Anyway** option is available for about an hour after the blocked
launch attempt. See Apple's guide to
[opening an app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)
for the current steps and security considerations.

### Building from source

```sh
git clone https://github.com/Bramgus12/container-gui.git
cd container-gui
open container-gui.xcodeproj
```

In Xcode, select the **Container GUI** scheme and press <kbd>⌘</kbd><kbd>R</kbd>.

## How it works

```mermaid
flowchart LR
    UI["Native SwiftUI interface"]
    MODEL["Typed app models"]
    CLIENT["ContainerCLI protocol"]
    PROCESS["Async process runner"]
    CLI["Apple container CLI"]
    SERVICE["Apple Container service"]

    UI --> MODEL --> CLIENT --> PROCESS --> CLI --> SERVICE
    CLI -->|"JSON, logs & progress"| PROCESS
    PROCESS -->|"Decoded results"| MODEL
```

Views never construct shell commands. Typed operations become discrete process
arguments, and JSON responses are decoded into app-owned models before they
reach the interface. The CLI layer is protocol-based, so tests can exercise the
complete workflow without touching real containers.

## Safety by design

Container management includes destructive and long-running operations, so the
app treats safety as a product feature:

- **No shell invocation.** The resolved executable is launched directly with
  validated, discrete arguments.
- **Confirmation before destructive actions.** Delete, force delete, image
  delete, network delete/prune, and service stop explain their impact before
  proceeding.
- **Cancellable work.** Long-running child processes are terminated when their
  operation is cancelled.
- **Bounded output.** Retained command output and logs are capped to prevent
  unbounded memory growth.
- **Sanitized diagnostics.** Environment values are excluded and common secret,
  token, password, credential, authorization, private-key, and URL-userinfo
  patterns are redacted.

## Development

Open [`container-gui.xcodeproj`](container-gui.xcodeproj) and use the
**Container GUI** scheme. The project includes:

- unit tests for command construction, decoding, validation, and feature models;
- fake-process integration tests for streaming, cancellation, and failures; and
- UI tests backed by an in-process fake CLI that never modifies real containers.

Run the full automated suite from Terminal:

```sh
xcodebuild test \
  -project container-gui.xcodeproj \
  -scheme "Container GUI" \
  -destination "platform=macOS"
```

Create an ad-hoc signed Release build and DMG with:

```sh
./scripts/release.sh
```

The outputs are written to `build/export/Container GUI.app` and
`build/export/Container-GUI.dmg`. The disk image includes an Applications
shortcut for drag-and-drop installation. These artifacts are not notarized;
see the [installation warning](#3-install-container-gui) above.

### Opt-in real smoke test

> [!CAUTION]
> Run this only on a disposable test Mac. It creates and removes a real
> container and network and may pull the configured image.

```sh
CONTAINER_GUI_RUN_REAL_SMOKE=1 \
CONTAINER_GUI_SMOKE_IMAGE=alpine:3.21 \
./scripts/real-smoke-test.sh
```

The script uses unique container and network names and targeted best-effort
cleanup. It attaches the smoke container to only that newly-created network,
deletes the image only if it was not present before the test, and never invokes
prune or another bulk deletion command.

## Current scope

Container GUI intentionally focuses on local container, image, network, and service
workflows. It does not yet manage:

- volumes or builds;
- registry authentication;
- interactive terminals;
- import and export;
- DNS or kernel settings;
- image or container prune operations; or
- remote container hosts.

New major Apple Container CLI versions remain unsupported until their JSON
formats have fixture and smoke-test coverage.

## Project resources

| Resource | Description |
| --- | --- |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Setup, service, upgrade, pull, and deletion help |
| [Release notes](docs/RELEASE_NOTES.md) | Container GUI 1.0 feature and compatibility summary |
| [Release checklist](docs/RELEASE_CHECKLIST.md) | Testing, accessibility, signing, and notarization gates |
| [Architecture decision](docs/decisions/0001-cli-wrapper-and-distribution.md) | Why the app wraps the CLI and ships outside the Mac App Store |

---

<div align="center">

Built with SwiftUI for Apple silicon.

</div>
