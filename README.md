<div align="center">

<img src="docs/app-icon.png" alt="CargoDeck app icon" width="160">

# CargoDeck

### Apple Container, without the command-line friction.

A native macOS control center for running containers, managing images,
watching resource usage, and keeping the Apple Container service healthy.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-111111?style=for-the-badge&logo=apple&logoColor=white)](#requirements)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)
[![Apple Container 0.12.3–<2.0](https://img.shields.io/badge/Apple%20Container-0.12.3–%3C2.0-3276D3?style=for-the-badge&logo=docker&logoColor=white)](https://github.com/apple/container)

[Get started](#getting-started) · [Explore features](#everything-you-need-in-one-window) · [Develop](#development) · [Troubleshoot](docs/TROUBLESHOOTING.md)

</div>

---

CargoDeck wraps Apple's [`container`](https://github.com/apple/container)
CLI in a focused SwiftUI experience. It handles the everyday container
workflow—from guided setup to logs and live statistics—while executing commands
directly, never through a shell.

## Everything you need in one window

| | Capability | What you can do |
| :---: | --- | --- |
| 📦 | **Containers** | Search, filter, run, create without starting, start, stop, signal, prune, and safely delete containers. |
| ⌨️ | **Commands & files** | Run a one-off command inside a running container, hand the interactive form to Terminal, copy files in and out, and export a container's filesystem as a tar archive. |
| 🔎 | **Deep inspection** | Explore structured container configuration, networking, ports, mounts, image variants, and OCI metadata. |
| 📜 | **Logs & stats** | Follow bounded logs and monitor CPU, memory, network, and block I/O. |
| 🖥️ | **Machines** | List, search, and inspect the long-lived Linux VMs `container machine` manages; create them with every flag pre-filled from what the CLI would compute; move the default; stop and delete. Needs CLI 1.0.0 or later. |
| 🐚 | **Machine shells** | Open a real login shell inside a machine in an embedded terminal, or run a one-off command, with environment, user, and working directory controls. |
| ⚙️ | **Boot configuration** | Edit CPUs, memory, home mount, nested virtualization, and the kernel as a running-versus-after-restart pair, because `container machine set` only takes effect on the next boot. |
| 🖼️ | **Images** | Search local images, inspect metadata, stream pull progress with scheme, platform and download-concurrency controls, run, and delete with dependency-aware cleanup. |
| 📦 | **Image transfer** | Tag an existing image, push it to a registry, save one or more images to a tar archive, and load an archive back — each cancellable, with the exact command shown before it runs. |
| 🧹 | **Image housekeeping** | Delete several named images or every image, and prune either dangling images or everything no container uses, with the scope re-checked against a fresh snapshot before it runs. |
| 🔑 | **Registries** | See which registry hosts the CLI is logged in to, log in with a user name and token, and log out. The password goes to the command's standard input and is never stored, previewed, or logged. |
| 🛠️ | **Builds** | Build tagged images from a local Dockerfile with arguments, labels, target/platform, cache, resource, pull, and output controls. |
| 💾 | **Volumes** | List, search, inspect, create, delete, and prune persistent volumes across Apple Container 0.12 and 1.x JSON shapes. |
| 📂 | **Container storage** | Mount named volumes or host folders into new containers, with optional read-only access. |
| 🌐 | **Networks** | List, search, inspect, create, delete, and prune networks, with Apple Container 0.12 and 1.x compatibility. |
| 🔗 | **Container networking** | Attach a new container to multiple networks with optional MAC addresses and MTUs. |
| 🧭 | **Local DNS** | Review resolver readiness, then set the service domain in `config.toml` and add or remove local domains in `/etc/resolver` — the app makes both changes for you, asking macOS to authenticate you for the one that needs root. |
| ❤️ | **System health** | Check CLI, server, and image-builder status; control their lifecycles; and review disk usage, the service configuration, and recent logs. |
| ⬆️ | **Update checks** | See when a newer CargoDeck release exists, read its notes, and copy the upgrade command. |
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
  **0.12.3 or later and earlier than 2.0.0**. The **Machines** screen needs
  **1.0.0 or later**, since that is when `container machine` was added; below it
  the screen is hidden rather than shown broken.
- Xcode, when building CargoDeck from source — see
  [Building from source](#building-from-source) for its two setup steps

### 2. Install Apple Container

Download Apple Container from its
[official releases](https://github.com/apple/container/releases) and complete
its installation. CargoDeck normally discovers the executable at
`/usr/local/bin/container` or `/opt/homebrew/bin/container`; you can also choose
a custom executable during onboarding.

### 3. Install CargoDeck

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/CargoDeck/main/scripts/install.sh | bash
```

The installer downloads the latest release disk image, checks its SHA-256
against the checksum GitHub publishes for the release asset, verifies the app's
code signature, and installs it into `/Applications`. Because releases are
notarized, macOS accepts the app on first launch with no approval step.

To read the script before running it:

```sh
curl -fsSL https://raw.githubusercontent.com/Bramgus12/CargoDeck/main/scripts/install.sh -o install.sh
```

Then review `install.sh` and run `bash install.sh`.

Useful options: `--version v1.2.0` pins a release, `--user` installs into
`~/Applications` and never asks for an administrator password, `--dir <path>`
chooses another location, and `--uninstall` removes the app while keeping its
settings. Re-running the command upgrades an existing installation in place.

On first launch, the app verifies the platform, executable, CLI version, and
service health before opening the main interface. If the service is installed
but stopped, it can be started directly from onboarding.

Once a day the app asks GitHub whether a newer release exists and shows the
result under **System → Updates**, where the check can also be run on demand or
turned off entirely. **CargoDeck → Check for Updates…** checks immediately.
Updating is always the same one-line command as installing.

> [!NOTE]
> CargoDeck releases are signed with a Developer ID Application certificate
> and notarized by Apple, and the notarization ticket is stapled to both the app
> and the disk image. Gatekeeper accepts them without any approval detour, and
> the check works offline. Releases up to and including 1.2.0 were ad-hoc signed
> and not notarized.

### Installing from the DMG by hand

Download `CargoDeck.dmg` from the
[releases page](https://github.com/Bramgus12/CargoDeck/releases) and compare
its SHA-256 with the checksum in the release notes:

```sh
shasum -a 256 ~/Downloads/CargoDeck.dmg
```

Open the disk image and drag **CargoDeck.app** to the Applications folder.
Because the app is Developer ID signed and notarized, macOS opens it after the
one-time "downloaded from the Internet" confirmation that every browser download
gets, in which it reports that Apple checked the app for malicious software.
There is no **Privacy & Security** detour. Confirm the signature and the stapled
notarization ticket yourself with:

```sh
spctl --assess --type execute --verbose=4 "/Applications/CargoDeck.app"
xcrun stapler validate "/Applications/CargoDeck.app"
```

If macOS does block the launch, the copy is damaged or was tampered with after
signing. Delete it, download the DMG again, and compare the checksum before
retrying rather than approving it in **Privacy & Security**.

### Building from source

The app depends on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm),
which provides the terminal emulator behind **Machines → Open Shell**. It is
resolved automatically by Swift Package Manager, but it brings two one-time
setup requirements with it.

SwiftTerm ships a Metal shader, so the Metal Toolchain component has to be
installed once per machine:

```bash
xcodebuild -downloadComponent MetalToolchain
```

Then clone and open the project:

```bash
git clone https://github.com/Bramgus12/CargoDeck.git && cd CargoDeck && open CargoDeck.xcodeproj
```

In Xcode, select the **CargoDeck** scheme and press <kbd>⌘</kbd><kbd>R</kbd>.
The first build asks you to trust SwiftTerm's SwiftPM build plugin; approve it
once and Xcode remembers.

Command-line builds cannot answer that prompt, so they pass
`-skipPackagePluginValidation`. `scripts/release.sh` and `scripts/test-release.sh`
already do:

```bash
xcodebuild -scheme "CargoDeck" -destination "platform=macOS" -skipPackagePluginValidation build
```

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
  validated, discrete arguments. The two commands that need root — creating and
  deleting a local DNS domain — are the one exception: they go through the macOS
  authentication dialog, which runs them in a shell, so every word of the command
  is single-quoted and every value it carries is validated first.
- **Administrator access only on request.** The app installs no privileged
  helper and holds no elevated rights. Each `/etc/resolver` change raises its own
  macOS password prompt, naming the domain it is about to change, and the copied
  `sudo` command stays available for anyone who would rather run it in Terminal.
- **Surgical config edits.** Setting the service DNS domain rewrites the one
  `domain` line under `[dns]` in `config.toml` and copies every other setting,
  comment, and blank line through unchanged. The write is atomic, and a file
  that states its DNS settings in a shape the app cannot edit safely is reported
  rather than rewritten.
- **Confirmation before destructive actions.** Delete, force delete, SIGKILL,
  container prune, image delete, network delete/prune, and service stop explain
  their impact before proceeding. Signals a process can handle are sent without
  a prompt.
- **Cancellable work.** Long-running child processes are terminated when their
  operation is cancelled.
- **Bounded output.** Retained command output and logs are capped to prevent
  unbounded memory growth.
- **Sanitized diagnostics.** Environment values are excluded and common secret,
  token, password, credential, authorization, private-key, and URL-userinfo
  patterns are redacted.

## Development

Open [`CargoDeck.xcodeproj`](CargoDeck.xcodeproj) and use the
**CargoDeck** scheme. The project includes:

- unit tests for command construction, decoding, validation, and feature models;
- fake-process integration tests for streaming, cancellation, and failures; and
- UI tests backed by an in-process fake CLI that never modifies real containers.

Run the full automated suite from Terminal:

```sh
xcodebuild test \
  -project CargoDeck.xcodeproj \
  -scheme "CargoDeck" \
  -destination "platform=macOS"
```

Create the Developer ID signed, notarized Release build and DMG with:

```sh
./scripts/release.sh
```

The outputs are written to `build/export/CargoDeck.app` and
`build/export/CargoDeck.dmg`. The disk image includes an Applications
shortcut for drag-and-drop installation. Both artifacts are signed with the
Developer ID Application certificate, notarized by Apple, and stapled.

This needs a Developer ID Application certificate in the keychain and notary
credentials stored once:

```sh
xcrun notarytool store-credentials cargodeck-notary \
  --apple-id <your Apple ID> --team-id CN495B7KTS --password <app-specific password>
```

Create the app-specific password at [account.apple.com](https://account.apple.com)
under **Sign-In and Security → App-Specific Passwords**. Run
`./scripts/release.sh --help` for the App Store Connect API key alternative and
the other overrides. `./scripts/release.sh --skip-notarization` produces a
signed but unpublishable build for local checks.

### Opt-in real smoke test

> [!CAUTION]
> Run this only on a disposable test Mac. It creates and removes a real
> container and network and may pull the configured image.

```sh
CARGODECK_RUN_REAL_SMOKE=1 \
CARGODECK_SMOKE_IMAGE=alpine:3.21 \
./scripts/real-smoke-test.sh
```

The script uses unique container and network names and targeted best-effort
cleanup. It attaches the smoke container to only that newly-created network,
deletes the image only if it was not present before the test, and never invokes
prune or another bulk deletion command.

## Current scope

CargoDeck intentionally focuses on local container, image, volume, network, build, and service
workflows. It does not yet manage:

- remote registry browsing — the CLI has no catalog, repository, or tag listing
  command, so there is nothing to browse against;
- storing registry credentials itself — the Apple Container CLI remains the
  credential store, and the app neither reads nor writes Keychain entries;
- build secrets or SSH forwarding;
- interactive terminals inside the app — a command that needs one is handed to
  Terminal instead;
- import;
- kernel settings; or
- remote container hosts.

New major Apple Container CLI versions remain unsupported until their JSON
formats have fixture and smoke-test coverage.

## Project resources

| Resource | Description |
| --- | --- |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Setup, service, upgrade, pull, registry, transfer, and deletion help |
| [Release notes](docs/RELEASE_NOTES.md) | Feature, compatibility, and upgrade notes for each release |
| [Release checklist](docs/RELEASE_CHECKLIST.md) | Testing, accessibility, signing, and notarization gates |
| [Architecture decision](docs/decisions/0001-cli-wrapper-and-distribution.md) | Why the app wraps the CLI and ships outside the Mac App Store |
| [CLI image/registry baseline](docs/CLI_IMAGE_REGISTRY_BASELINE.md) | The observed CLI surfaces the image and registry workflows are built against |

## License

CargoDeck is free software, licensed under the
[GNU General Public License v3.0](LICENSE). You may use, study, share, and
modify it; if you distribute the app or a modified version of it, you have to
pass the same freedoms on and make your source available under the same terms.

---

<div align="center">

Built with SwiftUI for Apple silicon.

</div>
