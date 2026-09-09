# ADR 0002: Running privileged DNS commands

## Status

Accepted. Supersedes the original decision recorded under this number, which was
titled "Copy privileged DNS commands" and said the app would never execute a
privileged DNS mutation. It executes them now, by two routes; the history is
kept below because the reasoning still explains the shape of the UI.

## Context

Apple Container creates and removes `/etc/resolver/containerization.<domain>`
files through `container system dns create` and `delete`. Those commands must
run as an administrator. CargoDeck has no privileged helper and does not
invoke a shell, as established by ADR 0001.

The original decision was that the app would render the exact
`sudo container system dns …` invocation and copy it for the user to run in
Terminal, so that the app needed no authorization plug-in, privileged helper,
shell, or password handling. Two things have changed since:

- The app grew a privileged runner (`OSAScriptPrivilegedCommandRunner`) that
  asks macOS to authenticate the user and runs the command with administrator
  privileges. The password is collected by the system, not by the app.
- The app grew a terminal emulator (`EmbeddedTerminalView` over
  `PseudoTerminalSession`) for machine shells. A pseudo-terminal is precisely
  what `sudo` needs in order to prompt, so running the command inside the app
  became possible.

## Decision

CargoDeck offers three routes to the same privileged change, and the UI
names the difference between them:

1. **The macOS authorization dialog** (the default; the "Add Domain" and
   "Remove" buttons). The system collects the password. The app never sees it.
   This remains the recommended path.
2. **`sudo` in the embedded terminal** ("Run with sudo…"). The command runs in a
   pseudo-terminal inside the sheet, showing real CLI output as it happens,
   which the authorization dialog cannot do. The user types the administrator
   password into a terminal the app renders.
3. **Copy Command.** Unchanged, for anyone who would rather run it themselves.

Route 2 is a deliberate trade and is documented as one. The password is typed
into CargoDeck's own terminal rather than the system's password dialog, and
keystrokes pass through `EmbeddedTerminalView.Coordinator.send(source:data:)` on
their way into the pty. The app does not store, echo, or log them, and the
banner at the top of the sheet says plainly whose terminal this is and offers
the macOS dialog instead. ADR 0001 is not weakened: `sudo` is invoked by
absolute path with the container executable as its first argument and the rest
as an argument vector, so no shell parses any of it.

The service domain in `config.toml` is unaffected by this ADR; it is written
directly, since it needs no privilege.

## Consequences

- The app still requires no authorization plug-in and no privileged helper.
- The app now handles a password in one specific, labelled place. It did not
  before, and that is the substantive change from the original decision.
- Route 2 reports completion itself: on a clean exit the sheet reloads DNS state
  from `/etc/resolver`, so the "run it and then request a re-check" round trip
  applies only to route 3.
- All three routes render the same invocation from the same argument-quoting
  implementation, so what is copied is what is run.
