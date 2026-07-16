import Foundation
import ProcrastinationBlockerCore

enum PrivilegedSessionStarter {
    static func start(
        duration: SessionDuration,
        domains: [BlockedDomain]
    ) async throws -> SessionState {
        try await Task.detached(priority: .userInitiated) {
            let helperURL = try resolveHelperURL()
            let requestURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("procrastination-blocker-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: requestURL) }

            let request = SessionRequest(domains: domains, requestedAt: Date())
            let requestData = try JSONEncoder().encode(request)
            try requestData.write(to: requestURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: requestURL.path
            )

            let shellCommand = [
                helperURL.path,
                "start",
                String(duration.seconds),
                requestURL.path,
            ]
            .map(shellQuote)
            .joined(separator: " ")

            let script = "do shell script \(appleScriptQuote(shellCommand)) with administrator privileges"
            let result = try runProcess(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script]
            )

            guard result.status == 0 else {
                if result.output.contains("(-128)") || result.output.localizedCaseInsensitiveContains("canceled") {
                    throw PrivilegedSessionError.authorizationCancelled
                }
                throw PrivilegedSessionError.helperFailed(result.output)
            }

            let stateURL = [
                SystemPaths.sessionStatePath,
                SystemPaths.stagedSessionStatePath,
            ]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let stateURL else {
                throw PrivilegedSessionError.missingActiveState
            }

            let stateData = try Data(contentsOf: stateURL)
            let state = try JSONDecoder().decode(SessionState.self, from: stateData)
            guard state.isActive else {
                throw PrivilegedSessionError.missingActiveState
            }
            return state
        }.value
    }

    private static func resolveHelperURL() throws -> URL {
        let installed = URL(fileURLWithPath: SystemPaths.helperPath)
        guard FileManager.default.isExecutableFile(atPath: installed.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: installed.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? NSNumber == 0,
              attributes[.groupOwnerAccountID] as? NSNumber == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0 else {
            throw PrivilegedSessionError.helperNotFound
        }

        return installed
    }

    private static func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

enum PrivilegedSessionError: LocalizedError {
    case helperNotFound
    case authorizationCancelled
    case helperFailed(String)
    case missingActiveState

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            return "The root-owned helper is missing or unsafe. Install the application with make install."
        case .authorizationCancelled:
            return "Administrator authorization was cancelled."
        case .helperFailed(let message):
            return message.isEmpty ? "The privileged helper could not start the session." : message
        case .missingActiveState:
            return "The helper finished without creating an active session."
        }
    }
}
