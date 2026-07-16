import Foundation

public enum HostsBlockError: Error, Equatable, Sendable {
    case malformedMarkers
}

public enum HostsBlock {
    public static func render(
        original: String,
        domains: [BlockedDomain]
    ) throws -> String {
        if domains.isEmpty,
           !original.contains(SystemPaths.managedBlockStartMarker),
           !original.contains(SystemPaths.managedBlockEndMarker) {
            return original
        }

        var lines = original.isEmpty
            ? []
            : original.components(separatedBy: "\n")

        let startIndices = lines.indices.filter {
            markerValue(of: lines[$0]) == SystemPaths.managedBlockStartMarker
        }
        let endIndices = lines.indices.filter {
            markerValue(of: lines[$0]) == SystemPaths.managedBlockEndMarker
        }

        let insertionIndex: Int
        if startIndices.isEmpty, endIndices.isEmpty {
            insertionIndex = lines.last == "" ? lines.index(before: lines.endIndex) : lines.endIndex
        } else if startIndices.count == 1,
                  endIndices.count == 1,
                  let start = startIndices.first,
                  let end = endIndices.first,
                  start < end {
            insertionIndex = start
            lines.removeSubrange(start...end)
        } else {
            throw HostsBlockError.malformedMarkers
        }

        let managedLines = renderedLines(for: domains)
        if !managedLines.isEmpty {
            lines.insert(contentsOf: managedLines, at: insertionIndex)
        }

        let rendered = lines.joined(separator: "\n")
        guard !rendered.isEmpty, !rendered.hasSuffix("\n") else {
            return rendered
        }

        return rendered + "\n"
    }

    private static func markerValue(of line: String) -> Substring {
        line.hasSuffix("\r") ? line.dropLast() : line[...]
    }

    private static func renderedLines(for domains: [BlockedDomain]) -> [String] {
        let sortedDomains = Set(domains).sorted()
        guard !sortedDomains.isEmpty else {
            return []
        }

        var lines = [SystemPaths.managedBlockStartMarker]
        for domain in sortedDomains {
            lines.append("0.0.0.0 \(domain.value)")
            lines.append("0.0.0.0 www.\(domain.value)")
        }
        lines.append(SystemPaths.managedBlockEndMarker)
        return lines
    }
}
