import AppKit
import ProcrastinationBlockerCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let menu = NSMenu()
    private let websiteStore = WebsiteStore()
    private var statusItem: NSStatusItem!
    private var settingsController: WebsiteSettingsWindowController!
    private var session: SessionState?
    private var cleanupPending = false
    private var countdownMenuItem: NSMenuItem?
    private var timer: Timer?
    private var startingSession = false
    private var workFocusInstalled: Bool?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settingsController = WebsiteSettingsWindowController(store: websiteStore)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        reloadSession()
        rebuildMenu()
        refreshWorkFocusStatus()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadSession()
                self?.rebuildMenu()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        reloadSession()
        rebuildMenu()
        refreshWorkFocusStatus()
    }

    private var activeSession: SessionState? {
        guard let session, session.isActive else { return nil }
        return session
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "lock.shield",
            accessibilityDescription: "Procrastination Blocker"
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.toolTip = "Procrastination Blocker"
    }

    private func tick() {
        let previousDeadline = activeSession?.endsAt
        let wasCleanupPending = cleanupPending
        reloadSession()
        if previousDeadline != activeSession?.endsAt || wasCleanupPending != cleanupPending {
            rebuildMenu()
        } else {
            if let activeSession {
                countdownMenuItem?.title = "\(formatRemaining(activeSession.remaining)) remaining"
            }
            updateStatusButton()
        }
    }

    private func reloadSession() {
        let url = [
            SystemPaths.sessionStatePath,
            SystemPaths.stagedSessionStatePath,
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.fileExists(atPath: $0.path) }

        guard let url else {
            session = nil
            cleanupPending = false
            return
        }

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SessionState.self, from: data) else {
            session = nil
            cleanupPending = true
            return
        }

        if decoded.isActive {
            session = decoded
            cleanupPending = false
        } else {
            session = nil
            cleanupPending = true
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        countdownMenuItem = nil

        if let activeSession {
            buildActiveMenu(for: activeSession)
        } else {
            buildIdleMenu()
        }
        updateStatusButton()
    }

    private func buildIdleMenu() {
        let title = cleanupPending ? "Finishing previous session…" : "Ready to focus"
        let heading = menuItem(title, enabled: false)
        heading.attributedTitle = attributed(title, weight: .semibold)
        menu.addItem(heading)
        menu.addItem(menuItem("\(websiteStore.domains.count) websites selected", enabled: false))
        menu.addItem(.separator())

        let start = menuItem(startingSession ? "Starting Session…" : "Start Focus Session")
        start.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        start.isEnabled = !startingSession
            && !cleanupPending
            && workFocusInstalled == true
        let durations = NSMenu(title: "Start Focus Session")
        for duration in SessionDuration.allCases {
            let item = NSMenuItem(
                title: duration.displayName,
                action: #selector(startSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = duration.seconds
            durations.addItem(item)
        }
        start.submenu = durations
        menu.addItem(start)

        let edit = menuItem("Edit Websites…", action: #selector(editWebsites))
        edit.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        edit.isEnabled = !startingSession && !cleanupPending
        menu.addItem(edit)

        menu.addItem(.separator())
        addWorkFocusMenuItem()
        addLoginItem()
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Procrastination Blocker", action: #selector(quit)))
    }

    private func buildActiveMenu(for session: SessionState) {
        let heading = menuItem("Focus session locked", enabled: false)
        heading.attributedTitle = attributed("Focus session locked", weight: .semibold)
        menu.addItem(heading)

        let remaining = menuItem("\(formatRemaining(session.remaining)) remaining", enabled: false)
        remaining.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        menu.addItem(remaining)
        countdownMenuItem = remaining
        menu.addItem(menuItem("Until \(formatDeadline(session.endsAt))", enabled: false))
        menu.addItem(menuItem("Blocking \(session.domains.count) websites", enabled: false))

        let sites = menuItem("Blocked Websites", enabled: true)
        let siteMenu = NSMenu(title: "Blocked Websites")
        for domain in session.domains {
            siteMenu.addItem(menuItem(domain.value, enabled: false))
        }
        sites.submenu = siteMenu
        menu.addItem(sites)

        menu.addItem(.separator())
        let immutable = menuItem("This session cannot be stopped early", enabled: false)
        immutable.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        menu.addItem(immutable)

        addLoginItem()
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Quit App (Blocking Continues)",
            action: #selector(quit)
        ))
    }

    private func addWorkFocusMenuItem() {
        switch workFocusInstalled {
        case true:
            let item = menuItem("Work Focus Shortcut Found", enabled: false)
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            menu.addItem(item)
        case false:
            let item = menuItem("Set Up Work Focus…", action: #selector(showWorkFocusSetup))
            item.image = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)
            menu.addItem(item)
        case nil:
            menu.addItem(menuItem("Checking Work Focus Shortcut…", enabled: false))
        }
    }

    private func addLoginItem() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        let item: NSMenuItem
        switch service.status {
        case .enabled:
            item = menuItem("Start at Login", action: #selector(toggleLogin))
            item.state = .on
        case .notRegistered:
            item = menuItem("Start at Login", action: #selector(toggleLogin))
            item.state = .off
        case .requiresApproval:
            item = menuItem("Start at Login (Approval Required)…", action: #selector(toggleLogin))
            item.state = .mixed
        case .notFound:
            item = menuItem("Start at Login Unavailable", enabled: false)
        @unknown default:
            item = menuItem("Start at Login Unavailable", enabled: false)
        }
        menu.addItem(item)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        if let activeSession {
            button.title = compactRemaining(activeSession.remaining)
            button.contentTintColor = .systemRed
            button.toolTip = "Focus locked until \(formatDeadline(activeSession.endsAt))"
        } else if startingSession {
            button.title = "…"
            button.contentTintColor = .systemOrange
            button.toolTip = "Starting focus session"
        } else if cleanupPending {
            button.title = "…"
            button.contentTintColor = .systemOrange
            button.toolTip = "Finishing the previous focus session"
        } else {
            button.title = ""
            button.contentTintColor = nil
            button.toolTip = "Procrastination Blocker"
        }
    }

    private func refreshWorkFocusStatus() {
        Task { [weak self] in
            let installed = await WorkFocusController.isInstalled()
            guard let self else { return }
            if self.workFocusInstalled != installed {
                self.workFocusInstalled = installed
                self.rebuildMenu()
            }
        }
    }

    @objc private func startSession(_ sender: NSMenuItem) {
        guard activeSession == nil,
              !cleanupPending,
              !startingSession,
              workFocusInstalled == true,
              let seconds = sender.representedObject as? Int,
              let duration = SessionDuration(seconds: seconds) else {
            return
        }

        settingsController.close()
        startingSession = true
        rebuildMenu()
        let domains = websiteStore.domains

        Task { [weak self] in
            guard let self else { return }
            do {
                let state = try await PrivilegedSessionStarter.start(
                    duration: duration,
                    domains: domains
                )
                self.session = state
                self.startingSession = false
                self.rebuildMenu()

                do {
                    try await WorkFocusController.activate(until: state.endsAt)
                    self.workFocusInstalled = true
                } catch {
                    self.showFocusFailure(error)
                }
            } catch {
                self.startingSession = false
                self.reloadSession()
                self.rebuildMenu()
                self.showAlert(
                    title: "Couldn’t Start Session",
                    message: error.localizedDescription
                )
            }
        }
    }

    @objc private func editWebsites() {
        guard activeSession == nil, !cleanupPending, !startingSession else { return }
        settingsController.present()
    }

    @objc private func showWorkFocusSetup() {
        let alert = NSAlert()
        alert.messageText = "Set Up Work Focus"
        alert.informativeText = "In Shortcuts, create “\(WorkFocusController.shortcutName)”. It should read the ISO-8601 date from Shortcut Input and use Set Focus to turn Work on until that date. The repository includes a detailed recipe in docs/work-focus-shortcut.md."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Shortcuts")
        alert.addButton(withTitle: "Copy Shortcut Name")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Shortcuts.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                WorkFocusController.shortcutName,
                forType: .string
            )
        default:
            break
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .notRegistered:
                try service.register()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notFound:
                throw LoginItemError.appNotInstalled
            @unknown default:
                throw LoginItemError.unknownStatus
            }
        } catch {
            showAlert(title: "Start at Login", message: error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showFocusFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Website Blocking Started"
        alert.informativeText = "The websites are blocked, but Work Focus could not be activated: \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Set Up Work Focus")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            showWorkFocusSetup()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func menuItem(
        _ title: String,
        action: Selector? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.isEnabled = enabled
        return item
    }

    private func attributed(_ title: String, weight: NSFont.Weight) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight)]
        )
    }

    private func formatRemaining(_ interval: TimeInterval) -> String {
        let total = max(0, Int(ceil(interval)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func compactRemaining(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(interval / 60)))
        return "\(minutes)m"
    }

    private func formatDeadline(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private enum LoginItemError: LocalizedError {
    case appNotInstalled
    case unknownStatus

    var errorDescription: String? {
        switch self {
        case .appNotInstalled:
            return "Install Procrastination Blocker in /Applications before enabling Start at Login."
        case .unknownStatus:
            return "macOS returned an unknown Start at Login status."
        }
    }
}
