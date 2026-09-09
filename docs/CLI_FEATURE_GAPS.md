# Container CLI feature gap audit

Audited 2026-09-06 against the current app source and installed Apple Container
CLI **1.3.1**, release build, commit **a9a62e2**.

## Scope and result

Enumerated all 61 built-in leaf commands using their actual `--help` output,
then inspected the installed experimental Kubernetes plugin and its six leaf
commands. Compared these with the app's command construction, services, models,
and UI call sites. Aliases are not separate features.

**14 commands have no dedicated app implementation: eight built-in commands and
six Kubernetes plugin commands.** The other 53 commands have an implementation
or an equivalent app workflow, but many expose only some CLI options.

This is a source and command-surface audit, not a runtime acceptance test. No
containers, images, machines, clusters, or services were created or changed.
The service was stopped: the CLI reported plugins unavailable. Kubernetes was
verified by reading `/usr/local/libexec/container/plugins/k8s/config.toml` and
running the installed plugin executable with `--help`; dispatch through
`container k8s` requires the service/plugin discovery to be available.

Apple's [versioned command reference](https://github.com/apple/container/blob/1.3.1/docs/command-reference.md)
is supporting documentation. Actual installed help takes precedence: for example,
it includes `--kernel-arg` on run/create and `--ulimit` on exec/machine run.
The audit does not assume options from a different release are available.

## Recently closed

`registry login`, `registry logout`, `registry list`, `image push`, `image tag`,
`image save`, `image load`, multi-image and `--all` deletion, and dedicated
image pruning all have app workflows now, along with `--scheme`, `--platform` /
`--os` / `--arch` and `--max-concurrent-downloads` on the transfer commands.
Two notes carried over from building them:

- `--scheme auto` exists on 0.12–1.0 and is **gone** on 1.3.1. The app's
  automatic choice therefore emits no flag at all rather than emitting `auto`.
- `--max-concurrent-downloads` arrived in 1.0.0 and is gated on that version.

See `docs/CLI_IMAGE_REGISTRY_BASELINE.md` for the captured surfaces.

Still absent from this area: remote registry catalog/repository/tag browsing
(the CLI has no such command), app-managed credential storage, and changing the
default registry in `runtime-config.toml`.

## Entirely missing commands

| Commands | Missing app workflow |
| --- | --- |
| `system kernel set` | Install/set the system default kernel from a binary or archive, use the recommended kernel, choose architecture, verify an archive digest, and force replacement. Per-machine custom kernels already exist. |
| `k8s create` | Create a local cluster with name, node image, CPU/memory, remove-on-stop, registry scheme, and download concurrency options. |
| `k8s list` | List clusters and their nodes. |
| `k8s start` | Start a stopped cluster. |
| `k8s delete` | Delete a cluster by name. |
| `k8s load-image` | Load a local image into a cluster's containerd, optionally selecting its platform. |
| `k8s write-config` | Write/merge cluster access configuration into a chosen kubeconfig file. |

Evidence: the complete typed command surface is
[ContainerCommand.swift](../CargoDeck/CLI/ContainerCommand.swift).
DNS has a separate implementation in
[DNSService.swift](../CargoDeck/CLI/DNSService.swift); none of the commands
above has a corresponding service or feature screen. Kubernetes is experimental
in the installed CLI and should be treated as an optional feature area.

## Missing options in run/create

The shared [RunConfiguration](../CargoDeck/Models/RunConfiguration.swift)
and [run form model](../CargoDeck/Features/Containers/RunContainerModel.swift)
currently support name, detach, remove-on-stop, CPU/memory, explicit environment
values, command/arguments, network attachments with MAC/MTU, DNS, published ports,
and named-volume/bind mounts with read-only access.

| Area | Missing options or behavior |
| --- | --- |
| Process identity and directory | `--user`, `--uid`, `--gid`, `--workdir`/`--cwd`. Exec already has user and working-directory fields; creation does not. |
| Environment input | `--env-file`; bare `--env KEY` to inherit a host value. The app always constructs `KEY=value`. |
| Interactive processes | `--interactive`, `--tty`, and a terminal/input channel for a foreground run. Disabling detach currently provides output, not an interactive terminal. |
| Entrypoint and init | `--entrypoint`, `--init`, `--init-image`. The command field does not provide an independent entrypoint override. |
| Platform and runtime | `--arch`, `--os`, `--platform`, `--rosetta`, `--runtime`, `--virtualization`. |
| Container kernel | `--kernel`, repeated `--kernel-arg`. These are separate from the implemented machine kernel setting. |
| Linux permissions and limits | `--cap-add`, `--cap-drop`, `--ulimit`. |
| Filesystem restrictions | Root `--read-only`; experimental `--masked-path` and `--read-only-path`, including their `NONE` reset behavior. Read-only individual mounts already exist. |
| Temporary/shared storage | `--tmpfs`, `--shm-size`. |
| Mount creation variants | Anonymous volumes and implicit creation of a new named volume during run/create. The app requires selecting an existing named volume and requires a mount source. Ordinary `--volume` bind/named-mount behavior is already covered through `--mount`. |
| Socket access | `--publish-socket`, `--ssh` agent forwarding. |
| Metadata/integration | Container `--label`, `--cidfile`. Image-build, volume, and network labels do exist. |

## Partial container lifecycle, exec, logs, and stats support

| Feature | Current limitation and evidence |
| --- | --- |
| Start attached/interactively | `start` always emits only the container ID. No `--attach` or `--interactive` choice in [ContainerCommand.swift](../CargoDeck/CLI/ContainerCommand.swift). |
| Stop timeout | `StopTimeout` and `--time` exist in the command layer, but the app always passes `timeout: nil` in [AppModel.swift](../CargoDeck/App/AppModel.swift). There is no UI timeout control. |
| Stop signal | No `stop --signal` support. Sending a signal with `kill` is a separate implemented action and does not expose the stop command's signal-plus-timeout behavior. |
| Bulk lifecycle actions | Stop, kill, and delete accept one selected container in the app, rather than multiple IDs or `--all`. Prune stopped containers is implemented. |
| Full signal selection | [KillSignal](../CargoDeck/Models/LifecycleModels.swift) allows TERM, KILL, INT, HUP, QUIT, USR1, and USR2 only; the CLI's broader signal input is not exposed. |
| Exec environment and limits | Missing `--env-file`, host environment inheritance, and `--ulimit`. Separate `--uid`/`--gid` flags are absent, though the existing `--user uid:gid` form covers common numeric-identity use. |
| Detached exec | Supported by `ExecConfiguration`, but [ExecModel](../CargoDeck/Features/Containers/ExecSheet.swift) never sets it and has no detach control. |
| Embedded container terminal | Interactive exec plumbing exists, but the container exec UI offers a one-shot command and an external Terminal handoff. No embedded container shell, or independent stdin/TTY controls. Embedded **machine** shells are implemented. |
| Container boot logs | Missing `logs --boot`; machine boot logs are implemented. |
| Container log tail selection | The detail model fixes the displayed tail at 500 lines; there is no custom `-n`/all-history control. See [ContainerDetailModel.swift](../CargoDeck/Features/Containers/ContainerDetailModel.swift). |
| Stats fields | `processCount` is decoded but never displayed. Per-container detail shows cumulative CPU time, not the CLI's live CPU percentage. Aggregate CPU rate is calculated separately by [ContainerStatsPoller.swift](../CargoDeck/Shared/ContainerStatsPoller.swift). |
| Batch inspection | Container/image/network/volume inspection takes one selected resource; no combined inspection of multiple IDs. |

Stats polling and log following are already implemented app behaviors; the fact
that they use snapshot commands internally is not itself a feature gap.

## Partial image/build/builder support

| Feature | Current limitation |
| --- | --- |
| Build secrets | No `--secret`, whether supplied through a host environment variable or a local file. |
| Build SSH | No `--ssh default`. |
| Build DNS | No `--dns`, `--dns-domain`, `--dns-option`, or `--dns-search`. Container run/create DNS is implemented. |
| Build multiplicity | The build form/configuration holds one tag and one platform/architecture/OS value. No multiple-tag workflow; no UI for a multi-target platform build. |
| Build integration | No custom `--vsock-port`. The app requires an explicit tag and absolute context directory instead of exposing the CLI's generated tag/current-directory defaults. |
| Builder startup DNS | Builder start exposes CPU and memory only, omitting its four DNS options. |
| Builder force deletion | No `builder delete --force`; the UI offers deletion for a stopped builder. |

Evidence: [BuildModels.swift](../CargoDeck/Models/BuildModels.swift),
[ImageBuildModel.swift](../CargoDeck/Features/Images/ImageBuildModel.swift),
[ContainerCommand.swift](../CargoDeck/CLI/ContainerCommand.swift), and
[SystemModel.swift](../CargoDeck/Features/System/SystemModel.swift).

## Partial machine support

All nine machine subcommands have app workflows, including create without boot,
default selection, embedded shell, boot logs, and editing/restarting boot settings.

- Creation omits `--platform` (including variant selection), `--scheme`, and
  `--max-concurrent-downloads`. Separate architecture and OS fields exist.
- Machine run omits `--ulimit`, host environment inheritance, and separate
  `--uid`/`--gid` flags. `--user uid:gid` covers common numeric-identity use.
- Machine run has one environment-file field, rather than multiple env files.
- The machine form always sets interactive and TTY to true; there are no
  independent no-stdin/no-TTY modes for one-shot commands. Detach is exposed.

Evidence: [MachineModels.swift](../CargoDeck/Models/MachineModels.swift) and
[MachineRunModel.swift](../CargoDeck/Features/Machines/MachineRunModel.swift).

## Partial network, volume, and system support

- **Networks and volumes:** creation options, list, single inspection/deletion,
  and prune are implemented. Missing batch inspection/deletion and explicit
  delete-all actions. Volume prune already provides an unused-volume cleanup
  workflow, so absence of `volume delete --all` is mainly an action/API difference.
- **Service startup:** no app-root, install-root, log-root, or startup-timeout
  controls. Startup hardcodes `--disable-kernel-install`; no install-kernel choice.
- **Service status/stop:** no custom launchd `--prefix`.
- **Service logs:** command layer supports follow and a period, but the UI loads
  a fixed last-15-minutes snapshot. No live service-log subscription or period
  selector. The viewer's jump-to-latest control only scrolls existing text.
- **System properties/configuration:** property listing is implemented. Only the
  DNS domain has a structured writer; other defaults require editing TOML outside
  the app. This is a configuration-editor gap, not a missing 1.3.1 `property set`
  command: that command is absent from this CLI version.
- **DNS:** list/create/delete and the create command's localhost redirect are
  implemented through the separate DNS service and privileged command runner.

Evidence: [ContainerCommand.swift](../CargoDeck/CLI/ContainerCommand.swift),
[SystemModel.swift](../CargoDeck/Features/System/SystemModel.swift),
[SystemView.swift](../CargoDeck/Features/System/SystemView.swift),
[ContainerConfigFile.swift](../CargoDeck/CLI/ContainerConfigFile.swift),
[NetworkCreateModel.swift](../CargoDeck/Features/Networks/NetworkCreateModel.swift),
and [VolumeCreateModel.swift](../CargoDeck/Features/Volumes/VolumeCreateModel.swift).

## CLI-oriented differences, not necessarily UI features to add

- Output-format selectors (JSON/table/YAML/TOML), quiet output, alternate progress
  renderers, and global debug mode are not exposed as general app controls.
  The app chooses formats for parsing and its own visual presentation.
- Container export always writes to a file; no stdout tar stream/pipeline mode.
- Copy uses absolute host/container paths; no relative-path entry behavior.
- Help flags and aliases are not missing workflows. CLI/server version reporting
  is already implemented.
- A generic command-plugin browser/launcher is absent. Network plugin selection
  already exists; Kubernetes is the installed command plugin audited here.
- Remote hosts, Compose, container commit/import, and unrelated Docker commands
  are not counted as gaps without corresponding commands in this CLI inventory.

## Suggested implementation order

1. Run/create user, working directory, env files, entrypoint, platform, labels,
   init, and read-only root filesystem: expands common launch configurations.
2. Container terminal, boot logs, stop timeout, and detached exec: several already
   have reusable command/session infrastructure.
3. Build secrets/SSH/DNS.
4. Kubernetes as a separate experimental feature area.
5. Kernel installation, advanced runtime/security flags, custom service roots,
   and the remaining batch/presentation controls.

The README's current-scope list is not sufficient for this audit: it omits
Kubernetes and image-distribution gaps, and its blanket terminal/kernel wording
does not reflect the existing machine terminal and per-machine kernel editor.
