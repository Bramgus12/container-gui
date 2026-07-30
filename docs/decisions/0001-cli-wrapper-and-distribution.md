# ADR 0001: Wrap the Apple Container CLI

- Status: Accepted
- Date: 2026-07-30

## Context

Container GUI needs to control Apple's separately installed `container` tool. The
application needs a stable boundary around process execution, must work with the
tool's background services and user-selected host files, and should be suitable
for automated testing without requiring a live container installation.

## Decision

The application will:

1. Wrap the supported `container` command-line interface behind a typed Swift
   protocol.
2. Launch an explicitly resolved, absolute executable URL with
   `Foundation.Process`.
3. Pass arguments through `Process.arguments`. It will never construct a shell
   command or invoke `/bin/sh`, `/bin/zsh`, or another shell.
4. Treat JSON emitted by supported read commands as an external data contract and
   decode it into app-owned models.
5. Ship outside the Mac App Store using Developer ID signing and notarization.
6. Disable App Sandbox because a sandboxed child process would not reliably have
   the access needed by a general-purpose container CLI frontend.
7. Keep Hardened Runtime enabled and avoid a privileged helper for the initial
   release.

The installed CLI remains a user-managed dependency. The application will not
silently install, update, or embed it.

## Consequences

- Process execution and JSON decoding can be replaced with fakes in unit tests.
- Views do not know CLI syntax and cannot interpolate untrusted values into a
  shell command.
- The application cannot be distributed through the Mac App Store under this
  architecture.
- File access is governed by the user's permissions. Future features that retain
  user-selected paths should persist URL bookmarks and revalidate access before
  use.
- Compatibility with CLI output must be tested against every supported CLI
  version.
