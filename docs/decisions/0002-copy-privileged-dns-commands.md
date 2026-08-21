# ADR 0002: Copy privileged DNS commands

## Status

Accepted

## Context

Apple Container creates and removes `/etc/resolver/containerization.<domain>`
files through `container system dns create` and `delete`. Those commands must
run as an administrator. Container GUI has no privileged helper and does not
invoke a shell, as established by ADR 0001.

## Decision

Container GUI reads DNS state directly, but never executes privileged DNS
mutations. It renders the exact `sudo container system dns …` invocation using
the existing argument-quoting implementation and copies it for the user to run
in Terminal. The app then offers a re-check that reads authoritative CLI and
resolver state. The service domain in `config.toml` remains read-only; the app
can reveal the file and copy the required TOML snippet.

## Consequences

- The app does not require an authorization plug-in, privileged helper, shell,
  or password handling.
- DNS mutations include a deliberate handoff to Terminal.
- The UI cannot report mutation completion until the user runs the command and
  requests a re-check.
