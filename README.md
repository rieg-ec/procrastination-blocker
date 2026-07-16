# Procrastination Blocker

A native macOS menu bar app for starting fixed website-blocking sessions. It
uses a root LaunchDaemon and a managed `/etc/hosts` block so quitting or
relaunching the menu bar app does not stop an active session.

Procrastination Blocker requires macOS 13 or later and Xcode or the Command
Line Tools with Swift 5.9 or later to build.

## Install

```sh
make install
```

This builds both release executables, creates and ad-hoc signs
`dist/ProcrastinationBlocker.app`, installs it at
`/Applications/ProcrastinationBlocker.app`, installs its minimal root-owned
session helper, and opens it. Installation requires administrator access.
Starting every session also asks for administrator authorization before the
root-owned helper snapshots and enforces the selected websites.

## Defaults and timers

The initial website roster is:

- `x.com`
- `instagram.com`
- `linkedin.com`
- `youtube.com`

The roster can be edited while idle. A session snapshots the current roster
and offers exactly four durations: 30, 60, 90, or 120 minutes.

## Session behavior

Starting a session validates the domains again with administrator privileges,
writes a root-owned snapshot under
`/Library/Application Support/ProcrastinationBlocker`, updates `/etc/hosts`,
and loads a root LaunchDaemon. The snapshot and deadline cannot be changed by
the menu bar app after the session starts. The daemon re-applies the block
every five seconds, survives app termination and Mac restarts, and removes the
managed hosts block and state after the fixed deadline.

There is deliberately no Stop button. Quitting the app only hides the status
and countdown; root enforcement continues. "Immutable" describes behavior
available to the ordinary user interface. It does not override the authority
of a macOS administrator.

## Work Focus Shortcut

macOS does not provide a public API for an app to turn on a named Focus.
Procrastination Blocker instead runs the public `/usr/bin/shortcuts` command
and passes the session deadline as ISO-8601 text.

Create a Shortcut named exactly **Procrastination Blocker - Work Focus**. It
must read the ISO-8601 deadline from its input, parse it as a date, and use:

1. `Set Focus`
2. Focus: `Work`
3. State: `On`
4. Until: `Time`, using the parsed deadline

The Start Session menu remains disabled until this Shortcut is found. This
preflight prevents knowingly starting a session without the requested Work
Focus integration. A later Shortcut execution failure is reported, but cannot
cancel a website-blocking session that has already committed.

The full action-by-action recipe is in
[`docs/work-focus-shortcut.md`](docs/work-focus-shortcut.md). A Shortcut
failure is reported by the app but does not undo a blocking session that has
already started.

To mirror Work Focus to other Apple devices signed into the same Apple
Account, enable **Share Across Devices** in System Settings > Focus. That
setting affects Focus synchronization only; it does not extend `/etc/hosts`
blocking to those devices.

## What is blocked

For each roster entry, `/etc/hosts` blocks the normalized exact domain and its
`www` form. For example, `example.com` blocks `example.com` and
`www.example.com`.

This is not wildcard filtering. It does not automatically block
`m.example.com`, `api.example.com`, embedded content on another hostname,
direct IP connections, or every endpoint used by a native app. Existing
connections and cached application behavior may also remain visible briefly.

## Threat model

The blocker is designed to resist impulsive cancellation through the app, not
to be a security boundary or parental-control system.

- A macOS administrator can unload the daemon, edit `/etc/hosts`, or remove
  the root helper and state before the deadline.
- A proxy that resolves names remotely, some VPN or custom networking setups,
  and software with its own resolver may bypass the local hosts file. A VPN
  does not inherently bypass it, but this cannot be guaranteed for every VPN.
- Alternate hostnames, direct IP addresses, another browser profile with
  unusual networking, another user-controlled device, or disabling the
  machine are outside the enforcement boundary.

## Launch at login

Choose **Start at Login** from the menu bar app. The app registers itself with
macOS using `SMAppService`; macOS also shows it under System Settings > General
> Login Items. Launching the UI at login is separate from root enforcement:
an already-active LaunchDaemon continues even when the UI is not running.

Disable **Start at Login** before deleting the app. If the app has already
been removed, disable its entry in Login Items.

## Development

```sh
make build       # release build of the app and helper
make test        # run XCTest through Swift Package Manager
make app         # build and ad-hoc sign dist/ProcrastinationBlocker.app
make clean       # remove .build and dist
```

## Uninstall

First disable **Start at Login**, then run:

```sh
make uninstall
```

Administrator access is required because uninstall deliberately bypasses an
active session. The target quits and removes the user app, unloads
`com.rieg.procrastination-blocker.enforcer`, removes exactly one valid managed
block from `/etc/hosts`, and deletes:

- `/Library/PrivilegedHelperTools/com.rieg.procrastination-blocker.enforcer`
- `/Library/LaunchDaemons/com.rieg.procrastination-blocker.enforcer.plist`
- `/Library/Application Support/ProcrastinationBlocker`
- `/Applications/ProcrastinationBlocker.app`

The managed hosts block is the content between
`# >>> procrastination blocker >>>` and
`# <<< procrastination blocker <<<`. Uninstall refuses to rewrite `/etc/hosts`
if those markers are duplicated, unmatched, or out of order; inspect and fix
the file as an administrator rather than risking removal of unrelated lines.

## License

MIT. See [`LICENSE`](LICENSE).
