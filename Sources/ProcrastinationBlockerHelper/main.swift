import Darwin
import Foundation
import ProcrastinationBlockerCore

private enum HelperError: Error, LocalizedError {
    case usage
    case invalidDuration
    case invalidRequest(String)
    case rootRequired
    case activeSession
    case unsafePath(String)
    case system(String)
    case launchctl(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: ProcrastinationBlockerHelper start <seconds> <request-json-path> | enforce | uninstall"
        case .invalidDuration:
            let seconds = SessionDuration.allCases.map(\.seconds).map(String.init).joined(separator: ", ")
            return "The duration must be one of: \(seconds) seconds."
        case .invalidRequest(let reason):
            return "Invalid session request: \(reason)"
        case .rootRequired:
            return "This command must run as root."
        case .activeSession:
            return "An active blocking session cannot be replaced."
        case .unsafePath(let path):
            return "Refusing to use an insecure system path: \(path)"
        case .system(let message):
            return message
        case .launchctl(let message):
            return "launchctl failed: \(message)"
        }
    }
}

private struct HelperRunner {
    private let maximumDomainCount = 1_000

    func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw HelperError.usage
        }

        switch command {
        case "start":
            guard arguments.count == 3,
                  let seconds = Int(arguments[1]) else {
                throw HelperError.usage
            }
            guard let duration = SessionDuration(seconds: seconds) else {
                throw HelperError.invalidDuration
            }

            try requireRoot()
            let request = try readRequest(at: arguments[2])
            let domains = try validatedDomains(request.domains)
            guard request.requestedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw HelperError.invalidRequest("requestedAt must be a finite date.")
            }

            try start(duration: duration, domains: domains)

        case "enforce":
            guard arguments.count == 1 else {
                throw HelperError.usage
            }

            try requireRoot()
            try enforce()

        case "uninstall":
            guard arguments.count == 1 else {
                throw HelperError.usage
            }

            try requireRoot()
            try uninstall()

        default:
            throw HelperError.usage
        }
    }

    private func readRequest(at path: String) throws -> SessionRequest {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HelperError.invalidRequest("unable to securely open the request file.")
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  isRegularFile(info.st_mode),
                  info.st_mode & 0o022 == 0,
                  info.st_size >= 0,
                  info.st_size <= 1_048_576 else {
                throw HelperError.invalidRequest("the request must be a secure regular file no larger than 1 MiB.")
            }

            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else {
                throw HelperError.invalidRequest("the request file is too large.")
            }
            return try JSONDecoder().decode(SessionRequest.self, from: data)
        } catch let error as HelperError {
            throw error
        } catch {
            throw HelperError.invalidRequest(error.localizedDescription)
        }
    }

    private func validatedDomains(_ domains: [BlockedDomain]) throws -> [BlockedDomain] {
        guard !domains.isEmpty else {
            throw HelperError.invalidRequest("at least one domain is required.")
        }
        guard domains.count <= maximumDomainCount else {
            throw HelperError.invalidRequest("too many domains.")
        }

        return Array(Set(domains)).sorted()
    }

    private func requireRoot() throws {
        guard geteuid() == 0 else {
            throw HelperError.rootRequired
        }
    }

    private func start(duration: SessionDuration, domains: [BlockedDomain]) throws {
        try ensureStateDirectory()
        let lock = try ExclusiveSystemLock(nonBlocking: true)
        defer { withExtendedLifetime(lock) {} }

        if let existingState = try readRootState() {
            if existingState.endsAt > Date() {
                throw HelperError.activeSession
            }

            try updateHosts(domains: [])
            try removeStateFiles()
        }

        try installHelper()
        try installLaunchDaemon()
        try reloadLaunchDaemon()

        let now = Date()
        let state = SessionState(
            domains: domains,
            startedAt: now,
            endsAt: now.addingTimeInterval(TimeInterval(duration.seconds))
        )
        try writeState(state, to: SystemPaths.stagedSessionStatePath)

        do {
            try updateHosts(domains: state.domains)
        } catch {
            try? removeStateFiles()
            throw error
        }

        do {
            try publishStagedState()
        } catch let publicationError {
            do {
                try updateHosts(domains: [])
                try removeStateFiles()
            } catch {
                // Keep staged root-owned state authoritative when rollback
                // fails. The waiting daemon will continue enforcing it.
                return
            }
            throw publicationError
        }
    }

    private func enforce() throws {
        try ensureStateDirectory()
        let lock = try ExclusiveSystemLock(nonBlocking: false)
        defer { withExtendedLifetime(lock) {} }

        while true {
            guard let state = try readRootState() else {
                try updateHosts(domains: [])
                return
            }

            let now = Date()
            if now >= state.endsAt {
                try updateHosts(domains: [])
                try removeStateFiles()
                return
            }

            try updateHosts(domains: state.domains)
            Thread.sleep(forTimeInterval: max(0, min(5, state.endsAt.timeIntervalSinceNow)))
        }
    }

    private func uninstall() throws {
        try stopLaunchDaemonIfLoaded()
        try ensureStateDirectory()
        let lock = try ExclusiveSystemLock(nonBlocking: false)
        defer { withExtendedLifetime(lock) {} }

        try updateHosts(domains: [])
        try removeStateFiles()

        for path in [SystemPaths.launchDaemonPlistPath, SystemPaths.helperPath] {
            if unlink(path) != 0, errno != ENOENT {
                throw currentSystemError("Unable to remove \(path)")
            }
        }
        try synchronizeDirectory(containing: SystemPaths.launchDaemonPlistPath)
        try synchronizeDirectory(containing: SystemPaths.helperPath)

        if unlink(SystemPaths.enforcementLockPath) != 0, errno != ENOENT {
            throw currentSystemError("Unable to remove the enforcement lock")
        }
        if rmdir(SystemPaths.rootStateDirectory) != 0, errno != ENOENT {
            throw currentSystemError("Unable to remove \(SystemPaths.rootStateDirectory)")
        }
    }

    private func ensureStateDirectory() throws {
        try ensureSecureDirectory(at: SystemPaths.rootStateDirectory, createIfMissing: true)
    }

    private func installHelper() throws {
        try ensureSecureDirectory(at: "/Library/PrivilegedHelperTools", createIfMissing: true)

        guard let executableURL = Bundle.main.executableURL else {
            throw HelperError.system("Unable to locate the running helper executable.")
        }

        let descriptor = open(executableURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HelperError.unsafePath(executableURL.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegularFile(info.st_mode),
              info.st_uid == 0,
              info.st_gid == 0,
              info.st_mode & 0o022 == 0 else {
            throw HelperError.unsafePath(executableURL.path)
        }

        let executableData: Data
        do {
            executableData = try handle.readToEnd() ?? Data()
        } catch {
            throw HelperError.system("Unable to read the running helper: \(error.localizedDescription)")
        }

        try atomicWrite(
            executableData,
            to: SystemPaths.helperPath,
            owner: 0,
            group: 0,
            mode: 0o755
        )
    }

    private func installLaunchDaemon() throws {
        try ensureSecureDirectory(at: "/Library/LaunchDaemons", createIfMissing: false)

        let propertyList: [String: Any] = [
            "Label": SystemPaths.launchDaemonLabel,
            "ProgramArguments": [SystemPaths.helperPath, "enforce"],
            "RunAtLoad": true,
            "KeepAlive": [
                "PathState": [
                    SystemPaths.sessionStatePath: true,
                    SystemPaths.stagedSessionStatePath: true,
                ],
            ],
            "ThrottleInterval": 5,
            "ProcessType": "Background",
        ]

        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: propertyList,
                format: .xml,
                options: 0
            )
        } catch {
            throw HelperError.system("Unable to encode the LaunchDaemon plist: \(error.localizedDescription)")
        }

        try atomicWrite(
            data,
            to: SystemPaths.launchDaemonPlistPath,
            owner: 0,
            group: 0,
            mode: 0o644
        )
    }

    private func reloadLaunchDaemon() throws {
        let serviceTarget = "system/\(SystemPaths.launchDaemonLabel)"
        let printResult = try launchctl(["print", serviceTarget])
        if printResult.status == 0 {
            try runLaunchctl(["bootout", serviceTarget])
        }

        try runLaunchctl([
            "bootstrap",
            "system",
            SystemPaths.launchDaemonPlistPath,
        ])
    }

    private func stopLaunchDaemonIfLoaded() throws {
        let serviceTarget = "system/\(SystemPaths.launchDaemonLabel)"
        let printResult = try launchctl(["print", serviceTarget])
        if printResult.status == 0 {
            try runLaunchctl(["bootout", serviceTarget])
        }
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        let result = try launchctl(arguments)
        guard result.status == 0 else {
            let message = result.output.isEmpty
                ? "exit status \(result.status)"
                : result.output
            throw HelperError.launchctl(message)
        }
    }

    private func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw HelperError.launchctl(error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }

    private func writeState(_ state: SessionState, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw HelperError.system("Unable to encode session state: \(error.localizedDescription)")
        }

        try atomicWrite(
            data,
            to: path,
            owner: 0,
            group: 0,
            mode: 0o644
        )
    }

    private func publishStagedState() throws {
        guard rename(SystemPaths.stagedSessionStatePath, SystemPaths.sessionStatePath) == 0 else {
            throw currentSystemError("Unable to publish session state")
        }
        // The rename is the commit point. A later directory-fsync error must
        // not make callers roll back state that is already visible.
        try? synchronizeDirectory(containing: SystemPaths.sessionStatePath)
    }

    private func readRootState() throws -> SessionState? {
        for path in [SystemPaths.sessionStatePath, SystemPaths.stagedSessionStatePath] {
            if let state = try readRootState(at: path) {
                return state
            }
        }
        return nil
    }

    private func readRootState(at path: String) throws -> SessionState? {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT {
                return nil
            }
            throw currentSystemError("Unable to inspect session state")
        }

        guard isRegularFile(info.st_mode),
              info.st_uid == 0,
              info.st_gid == 0,
              info.st_mode & 0o022 == 0 else {
            throw HelperError.unsafePath(path)
        }

        let state: SessionState
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            state = try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            throw HelperError.system("Unable to read root session state: \(error.localizedDescription)")
        }

        guard !state.domains.isEmpty,
              state.domains.count <= maximumDomainCount,
              Set(state.domains).count == state.domains.count,
              state.startedAt.timeIntervalSinceReferenceDate.isFinite,
              state.endsAt.timeIntervalSinceReferenceDate.isFinite,
              state.endsAt > state.startedAt else {
            throw HelperError.system("Root session state is invalid; refusing to replace or clear it.")
        }

        return state
    }

    private func removeStateFiles() throws {
        for path in [SystemPaths.sessionStatePath, SystemPaths.stagedSessionStatePath] {
            if unlink(path) != 0, errno != ENOENT {
                throw currentSystemError("Unable to remove expired session state")
            }
        }
        try? synchronizeDirectory(containing: SystemPaths.sessionStatePath)
    }

    private func updateHosts(domains: [BlockedDomain]) throws {
        let descriptor = open(SystemPaths.hostsPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw currentSystemError("Unable to inspect \(SystemPaths.hostsPath)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isRegularFile(info.st_mode),
              info.st_uid == 0,
              info.st_mode & 0o022 == 0 else {
            throw HelperError.unsafePath(SystemPaths.hostsPath)
        }

        let originalData: Data
        do {
            originalData = try handle.readToEnd() ?? Data()
        } catch {
            throw HelperError.system("Unable to read \(SystemPaths.hostsPath): \(error.localizedDescription)")
        }
        guard let original = String(data: originalData, encoding: .utf8) else {
            throw HelperError.system("\(SystemPaths.hostsPath) is not valid UTF-8.")
        }

        let rendered: String
        do {
            rendered = try HostsBlock.render(original: original, domains: domains)
        } catch {
            throw HelperError.system("Managed hosts markers are malformed; refusing to modify the file.")
        }

        let renderedData = Data(rendered.utf8)
        guard renderedData != originalData else {
            return
        }

        try atomicWrite(
            renderedData,
            to: SystemPaths.hostsPath,
            owner: info.st_uid,
            group: info.st_gid,
            mode: info.st_mode & 0o7777
        )
        flushDNSCache()
    }

    private func flushDNSCache() {
        runBestEffort(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"])
        runBestEffort(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"])
    }

    private func runBestEffort(executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The hosts file is authoritative; cache flushing is an optimization.
        }
    }

    private func ensureSecureDirectory(at path: String, createIfMissing: Bool) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT, createIfMissing else {
                throw currentSystemError("Unable to inspect \(path)")
            }
            guard mkdir(path, 0o755) == 0 else {
                throw currentSystemError("Unable to create \(path)")
            }
            guard chown(path, 0, 0) == 0 else {
                throw currentSystemError("Unable to set ownership for \(path)")
            }
            guard chmod(path, 0o755) == 0 else {
                throw currentSystemError("Unable to set permissions for \(path)")
            }
            guard lstat(path, &info) == 0 else {
                throw currentSystemError("Unable to verify \(path)")
            }
        }

        guard isDirectory(info.st_mode),
              info.st_uid == 0,
              info.st_gid == 0,
              info.st_mode & 0o022 == 0 else {
            throw HelperError.unsafePath(path)
        }
    }

    private func atomicWrite(
        _ data: Data,
        to destination: String,
        owner: uid_t,
        group: gid_t,
        mode: mode_t
    ) throws {
        let destinationPath = destination as NSString
        let directory = destinationPath.deletingLastPathComponent
        let filename = destinationPath.lastPathComponent
        var template = Array("\(directory)/.\(filename).XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw currentSystemError("Unable to create a temporary file for \(destination)")
        }

        let temporaryPath = String(cString: template)
        var descriptorIsOpen = true
        var temporaryFileExists = true
        defer {
            if descriptorIsOpen {
                Darwin.close(descriptor)
            }
            if temporaryFileExists {
                unlink(temporaryPath)
            }
        }

        guard fchown(descriptor, owner, group) == 0 else {
            throw currentSystemError("Unable to set ownership for \(temporaryPath)")
        }
        guard fchmod(descriptor, mode) == 0 else {
            throw currentSystemError("Unable to set permissions for \(temporaryPath)")
        }

        try writeAll(data, to: descriptor, path: temporaryPath)
        guard fsync(descriptor) == 0 else {
            throw currentSystemError("Unable to synchronize \(temporaryPath)")
        }

        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw currentSystemError("Unable to close \(temporaryPath)")
        }

        guard rename(temporaryPath, destination) == 0 else {
            throw currentSystemError("Unable to replace \(destination)")
        }
        temporaryFileExists = false
        // Data and the file itself were fsynced before rename. Treat rename as
        // committed even if the best-effort directory fsync is unavailable.
        try? synchronizeDirectory(containing: destination)
    }

    private func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }

            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw currentSystemError("Unable to write \(path)")
                }
                offset += result
            }
        }
    }

    private func synchronizeDirectory(containing path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw currentSystemError("Unable to open \(directory) for synchronization")
        }
        defer { Darwin.close(descriptor) }

        guard fsync(descriptor) == 0 else {
            throw currentSystemError("Unable to synchronize \(directory)")
        }
    }

    private func isRegularFile(_ mode: mode_t) -> Bool {
        mode & S_IFMT == S_IFREG
    }

    private func isDirectory(_ mode: mode_t) -> Bool {
        mode & S_IFMT == S_IFDIR
    }

    private func currentSystemError(_ operation: String) -> HelperError {
        let code = errno
        return .system("\(operation): \(String(cString: strerror(code)))")
    }
}

private final class ExclusiveSystemLock {
    private let descriptor: Int32

    init(nonBlocking: Bool) throws {
        descriptor = open(
            SystemPaths.enforcementLockPath,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw HelperError.system("Unable to open the enforcement lock: \(String(cString: strerror(errno)))")
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0,
              info.st_gid == 0 else {
            Darwin.close(descriptor)
            throw HelperError.unsafePath(SystemPaths.enforcementLockPath)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw HelperError.system("Unable to secure the enforcement lock: \(message)")
        }

        let operation = LOCK_EX | (nonBlocking ? LOCK_NB : 0)
        guard flock(descriptor, operation) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if nonBlocking && (code == EWOULDBLOCK || code == EAGAIN) {
                throw HelperError.activeSession
            }
            throw HelperError.system("Unable to acquire the enforcement lock: \(String(cString: strerror(code)))")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

do {
    try HelperRunner().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = "error: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
