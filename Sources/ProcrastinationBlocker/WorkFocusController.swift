import Foundation

enum WorkFocusController {
    static let shortcutName = "Procrastination Blocker - Work Focus"

    static func isInstalled() async -> Bool {
        await Task.detached(priority: .utility) {
            guard let result = try? runShortcuts(arguments: ["list"]), result.status == 0 else {
                return false
            }

            return result.output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .contains(shortcutName)
        }.value
    }

    static func activate(until deadline: Date) async throws {
        try await Task.detached(priority: .userInitiated) {
            let inputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("procrastination-blocker-focus-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: inputURL) }

            let formatter = ISO8601DateFormatter()
            let input = formatter.string(from: deadline) + "\n"
            try Data(input.utf8).write(to: inputURL, options: [.atomic])

            let result = try runShortcuts(arguments: [
                "run",
                shortcutName,
                "--input-path",
                inputURL.path,
            ])
            guard result.status == 0 else {
                throw WorkFocusError.activationFailed(result.output)
            }
            guard result.output == "success" else {
                throw WorkFocusError.invalidOutput(result.output)
            }
        }.value
    }

    private static func runShortcuts(
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
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
}

enum WorkFocusError: LocalizedError {
    case activationFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .activationFailed(let message):
            return message.isEmpty
                ? "The Work Focus Shortcut could not be run."
                : message
        case .invalidOutput(let output):
            return output.isEmpty
                ? "The Work Focus Shortcut did not return “success”. Check its final Stop and Output action."
                : "The Work Focus Shortcut returned “\(output)” instead of “success”."
        }
    }
}
