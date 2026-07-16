# Procrastination Blocker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu-bar application that edits a website roster, starts immutable 30/60/90/120-minute blocking sessions, and activates the user's Work Focus through an Apple Shortcut.

**Architecture:** A dependency-free Swift package produces a menu-bar application, a shared core library, and a root enforcement helper. The UI stores only the editable idle roster; starting a session asks for administrator authorization, snapshots validated domains into root-owned state, updates `/etc/hosts`, and starts a LaunchDaemon that keeps enforcing until the fixed deadline even if the UI quits or the Mac restarts. Work Focus uses Apple's public `shortcuts` CLI because macOS has no public API for directly activating a named Focus.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Foundation, ServiceManagement, Swift Package Manager, XCTest, launchd, `/etc/hosts`, macOS Shortcuts.

---

## File map

- `Package.swift`: library, application, helper, and test targets.
- `Sources/ProcrastinationBlockerCore/Domain.swift`: durations, normalized domains, session requests, and root session state.
- `Sources/ProcrastinationBlockerCore/HostsBlock.swift`: pure, validated managed-block rendering for `/etc/hosts`.
- `Sources/ProcrastinationBlockerCore/SystemPaths.swift`: privileged paths and launchd label shared by app and helper.
- `Sources/ProcrastinationBlocker/App.swift`: AppKit process entry point.
- `Sources/ProcrastinationBlocker/AppDelegate.swift`: status item, menus, countdown, session start, login item, and notifications.
- `Sources/ProcrastinationBlocker/WebsiteStore.swift`: editable persisted roster with built-in defaults.
- `Sources/ProcrastinationBlocker/WebsiteSettingsWindowController.swift`: native settings window for adding and removing domains.
- `Sources/ProcrastinationBlocker/PrivilegedSessionStarter.swift`: administrator prompt and bundled-helper invocation.
- `Sources/ProcrastinationBlocker/WorkFocusController.swift`: detects and runs the configured Work Focus Shortcut until the session deadline.
- `Sources/ProcrastinationBlockerHelper/main.swift`: strict root command surface for `start` and `enforce`.
- `packaging/Info.plist`: agent app metadata and menu-bar-only behavior.
- `Makefile`: build, test, app bundling, install, uninstall, and cleanup.
- `Tests/ProcrastinationBlockerCoreTests/DomainTests.swift`: duration and domain validation tests.
- `Tests/ProcrastinationBlockerCoreTests/HostsBlockTests.swift`: managed-block preservation and malformed-marker tests.
- `.github/workflows/test.yml`: macOS Swift build and test checks.
- `README.md`: installation, behavior, threat model, Work Focus setup, and uninstall instructions.
- `docs/work-focus-shortcut.md`: exact public-API Shortcut recipe.

## Task 1: Establish the Swift package and core domain

**Files:** `Package.swift`, `Sources/ProcrastinationBlockerCore/Domain.swift`, `Sources/ProcrastinationBlockerCore/SystemPaths.swift`, `Tests/ProcrastinationBlockerCoreTests/DomainTests.swift`

- [x] Write tests that accept `x.com`, normalize pasted HTTPS URLs, reject ports/whitespace/invalid labels, expose exactly 30/60/90/120-minute options, and reject all other privileged durations.
- [x] Run `swift test` and verify the target fails because the core types do not exist.
- [x] Implement `BlockedDomain`, `SessionDuration`, `SessionRequest`, and `SessionState` as Codable/Sendable value types. Domain normalization strips scheme, path, query, a leading `www.`, and a trailing dot before strict DNS-label validation.
- [x] Add constants for the launchd label, root state directory, helper path, plist path, hosts path, and managed block markers.
- [x] Run `swift test` and verify all domain tests pass.

## Task 2: Implement safe hosts-file transformation

**Files:** `Sources/ProcrastinationBlockerCore/HostsBlock.swift`, `Tests/ProcrastinationBlockerCoreTests/HostsBlockTests.swift`

- [x] Write tests proving unrelated hosts content is byte-for-byte represented in the transformed line model, each domain and its `www` form are blocked, an empty set removes only the managed block, duplicate markers fail closed, and an unmatched marker never truncates the file.
- [x] Run the focused hosts tests and verify they fail.
- [x] Implement a pure `HostsBlock.render(original:domains:)` transformation that accepts either no markers or exactly one ordered pair and throws `HostsBlockError.malformedMarkers` otherwise.
- [x] Render deterministic sorted entries between `# >>> procrastination blocker >>>` and `# <<< procrastination blocker <<<` using `0.0.0.0`, with a trailing newline.
- [x] Run `swift test` and verify all hosts tests pass.

## Task 3: Build immutable privileged session enforcement

**Files:** `Sources/ProcrastinationBlockerHelper/main.swift`

- [x] Implement `start <allowed-duration> <request-json>` so it validates the request again as root, refuses to replace an active root-owned state file, installs a root-owned helper and LaunchDaemon, applies the hosts block, and publishes the immutable state as the final commit point.
- [x] Implement `enforce` so it obtains an exclusive system lock, repeatedly reloads only root-owned session state, re-applies the immutable domain snapshot every five seconds, and clears the managed hosts block and state after the deadline.
- [x] Preserve `/etc/hosts` owner and mode during same-directory atomic replacement; never execute roster contents as shell code.
- [x] Keep the installed helper under `/Library/PrivilegedHelperTools` and state under `/Library/Application Support/ProcrastinationBlocker`, both `root:wheel` and non-user-writable.
- [x] Build the helper with `swift build` and manually exercise non-root argument validation without modifying `/etc/hosts`.

## Task 4: Add roster editing and the settings window

**Files:** `Sources/ProcrastinationBlocker/WebsiteStore.swift`, `Sources/ProcrastinationBlocker/WebsiteSettingsWindowController.swift`

- [x] Register the defaults `x.com`, `instagram.com`, `linkedin.com`, and `youtube.com` when no saved roster exists.
- [x] Persist a normalized, ordered, duplicate-free roster through `UserDefaults` and expose validation failures to the UI.
- [x] Create a SwiftUI settings view hosted in a standard AppKit window with a domain field, Add button, removable list rows, Reset Defaults, and Done.
- [x] Prevent removing the final domain and close the window before a session starts so the roster snapshot cannot drift during authorization.
- [x] Build the app target and verify the settings window compiles on macOS 13 or later.

## Task 5: Add session start and Work Focus integration

**Files:** `Sources/ProcrastinationBlocker/PrivilegedSessionStarter.swift`, `Sources/ProcrastinationBlocker/WorkFocusController.swift`, `docs/work-focus-shortcut.md`

- [x] Resolve and verify the root-owned helper installed under `/Library/PrivilegedHelperTools`; never elevate a helper directly from the user-writable app bundle.
- [x] Encode a validated temporary `SessionRequest`, invoke the helper through `do shell script … with administrator privileges`, and delete the request on every result path.
- [x] Detect the namespaced Shortcut `Procrastination Blocker - Work Focus` using `/usr/bin/shortcuts list`.
- [x] After blocking starts, run the Shortcut with an ISO-8601 deadline through `--input-path`; report failure without rolling back the already-started blocking session.
- [x] Document the exact Shortcut recipe: receive the date input, use `Set Focus` to turn `Work` on until that date, and output success.

## Task 6: Build the menu-bar experience

**Files:** `Sources/ProcrastinationBlocker/App.swift`, `Sources/ProcrastinationBlocker/AppDelegate.swift`

- [x] Bootstrap an accessory AppKit app and retain a variable-width `NSStatusItem` using the `lock.shield` SF Symbol.
- [x] In idle state, show the website count, a Start Session submenu containing 30/60/90/120 minutes, Edit Websites, Work Focus setup/status, Start at Login, and Quit.
- [x] In active state, show a live countdown, blocked-domain count, fixed deadline, and “This session cannot be stopped early”; provide no stop action and label Quit as “Quit App (Blocking Continues).”
- [x] Poll root state once per second, restore active UI after app relaunch, and let the LaunchDaemon remain authoritative.
- [x] Use `SMAppService.mainApp` for launch at login and user alerts for authorization and Work Focus outcomes.

## Task 7: Package, document, and verify

**Files:** `packaging/Info.plist`, `Makefile`, `.gitignore`, `.github/workflows/test.yml`, `README.md`

- [x] Package both release executables into `ProcrastinationBlocker.app`, place the helper in `Contents/Helpers`, set `LSUIElement`, and ad-hoc sign the complete bundle.
- [x] Add `make build`, `make test`, `make app`, `make install`, `make uninstall`, and `make clean` targets.
- [x] Document that the lock resists impulsive UI cancellation but is not a security boundary against a macOS administrator, proxy/VPN, alternate device, or manual privileged removal.
- [x] Document that `/etc/hosts` blocks exact domains plus `www`, and explain Work Focus Shortcut setup and Share Across Devices behavior.
- [x] Add GitHub Actions that runs `swift build` and `swift test` on macOS.
- [x] Run `swift test`, `swift build -c release`, `make app`, `codesign --verify --deep --strict dist/ProcrastinationBlocker.app`, and inspect the bundle contents.
- [ ] Inspect `git status`, `git diff`, and recent history; commit the complete independently usable application with an English conventional commit.
