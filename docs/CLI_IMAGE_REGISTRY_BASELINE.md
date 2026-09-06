# Image and registry CLI baseline

What the Apple Container CLI actually accepts for the image and registry
commands, captured before the GUI work so argument order, flag spelling and
version gating are based on observed behaviour rather than assumption.

- **Observed directly:** `container` 1.3.1 (build: release, commit `a9a62e2`) on
  macOS 26, Apple silicon. Every `--help` below was run against that binary.
- **Read from Apple's published command reference:** [0.12.0] and [1.0.0]. No
  0.12.x binary was available on the capture machine, so the older surface is
  taken from Apple's versioned documentation rather than from a live run. This
  is the one gap in the capture, and it is the reason the two version-sensitive
  decisions below are conservative.

[0.12.0]: https://github.com/apple/container/blob/0.12.0/docs/command-reference.md
[1.0.0]: https://github.com/apple/container/blob/1.0.0/docs/command-reference.md

No mutating command was invoked during the capture.

## The two version differences that matter

### 1. `--scheme` lost its `auto` value

| Release | Accepted values | Default |
| --- | --- | --- |
| 0.12.0 | `http`, `https`, `auto` | `auto` |
| 1.0.0 | `http`, `https`, `auto` | `auto` |
| 1.3.1 | `http`, `https` | `https` |

`--scheme auto` is therefore **rejected on current releases**. This is why
`RegistryScheme.auto` emits no flag at all rather than emitting `auto`:

- on 0.12–1.0, omitting the flag gives `auto`, which is what the user asked for;
- on 1.3.1, omitting the flag gives `https`, the only sensible automatic choice
  now available.

An explicit `https` or `http` is emitted verbatim and is valid on every
supported release. Nothing in the app ever emits the string `auto`, and
`ImageOperationModelTests.testAutomaticSchemeEmitsNoFlag` pins that.

### 2. `--max-concurrent-downloads` arrived in 1.0.0

Absent from the 0.12.0 `image pull` surface; present in 1.0.0 and 1.3.1 with a
default of 3. `ImageCapabilities` gates it at 1.0.0, and the pull sheet omits
the field entirely below that rather than disabling it — an option that cannot
work is better not offered.

## Captured `--help` output (CLI 1.3.1)

### `container registry`

```
SUBCOMMANDS:
  login                   Log in to a registry
  logout                  Log out from a registry
  list, ls                List image registry logins
```

```
USAGE: container registry login [--scheme <scheme>] [--password-stdin] [--username <username>] [--debug] <server>
ARGUMENTS:
  <server>                Registry server name
OPTIONS:
  --scheme <scheme>       Scheme to use when connecting to the container
                          registry. One of (http, https) (default: https)
  --password-stdin        Take the password from stdin
  -u, --username <username>
                          Registry user name
```

```
USAGE: container registry logout [--debug] <registry>
ARGUMENTS:
  <registry>              Registry server name
```

```
USAGE: container registry list [--debug] [--format <format>] [--quiet]
OPTIONS:
  --format <format>       Format of the output (values: json, table, yaml,
                          toml; default: table)
  -q, --quiet             Only output the registry hostname
```

`--quiet` is what the GUI parses: it prints one hostname per line, the UI needs
host identity only, and the structured shapes have moved between releases.

### `container image pull`

```
USAGE: container image pull [--scheme <scheme>] [--progress <type>] [--max-concurrent-downloads <max-concurrent-downloads>] [--arch <arch>] [--os <os>] [--platform <platform>] [--debug] <reference>
OPTIONS:
  --scheme <scheme>       ... One of (http, https) (default: https)
  --progress <type>       Progress type (format: auto|none|ansi|plain|color)
                          (default: auto)
  --max-concurrent-downloads <max-concurrent-downloads>
                          Maximum number of concurrent downloads (default: 3)
  -a, --arch <arch>       Limit the pull to the specified architecture
  --os <os>               Limit the pull to the specified OS
  --platform <platform>   Limit the pull to the specified platform (format:
                          os/arch[/variant], takes precedence over --os and
                          --arch)
```

`--progress plain` is valid on 0.12.0 (`none|ansi|plain|color`) and on 1.3.1
(which adds `auto` and defaults to it), so the GUI can force it everywhere.

### `container image push`

```
USAGE: container image push [--scheme <scheme>] [--progress <type>] [--arch <arch>] [--os <os>] [--platform <platform>] [--debug] <reference>
```

Same options as pull minus the download-concurrency limit.

### `container image tag`

```
USAGE: container image tag <source> <target> [--debug]
ARGUMENTS:
  <source>                The existing image reference (format: image-name[:tag])
  <target>                The new image reference
```

### `container image save`

```
USAGE: container image save [--arch <arch>] [--os <os>] [--output <output>] [--platform <platform>] [--debug] <references> ...
OPTIONS:
  -a, --arch <arch>       Architecture for the saved image
  --os <os>               OS for the saved image
  -o, --output <output>   Pathname for the saved image
  --platform <platform>   Platform for the saved image (...)
```

References are variadic positionals, so every option is emitted before them.

### `container image load`

```
USAGE: container image load [--input <input>] [--force] [--debug]
OPTIONS:
  -i, --input <input>     Path to the image tar archive
  -f, --force             Load images even if the archive contains invalid files
```

The GUI's wording for `--force` follows this literally: it accepts an archive
containing invalid member files. It is not a general "ignore failures" switch.

### `container image delete`

```
USAGE: container image delete [--all] [--force] [<images> ...] [--debug]
OPTIONS:
  -a, --all               Delete all images
  -f, --force             Ignore errors for images that are not found
```

`--force` here means *ignore missing targets*. It does **not** remove an image a
container is using, which is why the GUI labels it "Ignore targets that are
already missing" and never "force delete".

### `container image prune`

```
USAGE: container image prune [--debug] [--all]
OPTIONS:
  -a, --all               Remove all unused images, not just dangling ones
```

Two scopes, and the GUI offers exactly those two.

## Not captured

Success, failure and cancellation *output* for pull, push, save, load, delete
and prune was not recorded: doing so needs a disposable registry and a
throwaway image set, and every one of those commands mutates something. The GUI
does not parse any of it — the shared operation activity shows the last line
verbatim and only claims a progress fraction when a line carries an `n / m`
pair — so nothing in the app depends on wording that was not observed. Recording
it belongs with the opt-in real smoke test, alongside the login/logout capture
that needs a disposable registry.
