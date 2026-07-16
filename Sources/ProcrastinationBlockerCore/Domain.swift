import Foundation

public enum SessionDuration: Int, CaseIterable, Codable, Sendable {
    case thirtyMinutes = 30
    case sixtyMinutes = 60
    case ninetyMinutes = 90
    case oneHundredTwentyMinutes = 120

    public init?(seconds: Int) {
        guard seconds.isMultiple(of: 60) else {
            return nil
        }

        self.init(rawValue: seconds / 60)
    }

    public var minutes: Int {
        rawValue
    }

    public var seconds: Int {
        minutes * 60
    }

    public var displayName: String {
        "\(minutes) minutes"
    }
}

public enum BlockedDomainError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case containsWhitespace
    case unsupportedScheme
    case credentialsNotAllowed
    case portNotAllowed
    case invalidHostname

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The domain cannot be empty."
        case .containsWhitespace:
            return "The domain cannot contain whitespace."
        case .unsupportedScheme:
            return "Only HTTP and HTTPS URLs are supported."
        case .credentialsNotAllowed:
            return "The domain cannot contain credentials."
        case .portNotAllowed:
            return "The domain cannot contain a port."
        case .invalidHostname:
            return "The domain is not a valid hostname."
        }
    }
}

public struct BlockedDomain: Hashable, Comparable, Codable, Sendable {
    public let value: String

    public init(_ input: String) throws {
        value = try Self.normalize(input)
    }

    public static func normalize(_ input: String) throws -> String {
        guard !input.isEmpty else {
            throw BlockedDomainError.empty
        }
        guard input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw BlockedDomainError.containsWhitespace
        }

        var remainder = input[...]
        if let separator = remainder.range(of: "://") {
            let scheme = remainder[..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else {
                throw BlockedDomainError.unsupportedScheme
            }
            remainder = remainder[separator.upperBound...]
        }

        let authorityEnd = remainder.firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? remainder.endIndex
        let authority = remainder[..<authorityEnd]

        guard !authority.isEmpty else {
            throw BlockedDomainError.empty
        }
        guard !authority.contains("@") else {
            throw BlockedDomainError.credentialsNotAllowed
        }
        guard !authority.contains(":") else {
            throw BlockedDomainError.portNotAllowed
        }

        var hostname = authority.lowercased()
        if hostname.hasSuffix(".") {
            hostname.removeLast()
        }
        if hostname.hasPrefix("www.") {
            hostname.removeFirst(4)
        }

        guard Self.isValidHostname(hostname) else {
            throw BlockedDomainError.invalidHostname
        }

        return hostname
    }

    public static func < (lhs: BlockedDomain, rhs: BlockedDomain) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let input = try container.decode(String.self)

        do {
            try self.init(input)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid blocked domain: \(error.localizedDescription)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func isValidHostname(_ hostname: String) -> Bool {
        guard hostname.count <= 253 else {
            return false
        }

        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy(isValidLabel),
              labels.last?.contains(where: isASCIILetter) == true else {
            return false
        }

        return true
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count),
              let first = label.unicodeScalars.first,
              let last = label.unicodeScalars.last,
              isASCIILetterOrNumber(first),
              isASCIILetterOrNumber(last) else {
            return false
        }

        return label.unicodeScalars.allSatisfy { scalar in
            isASCIILetterOrNumber(scalar) || scalar.value == 45
        }
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.unicodeScalars.count == 1
            && character.unicodeScalars.first.map(isASCIILetter) == true
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIILetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (48...57).contains(scalar.value)
    }
}

public struct SessionRequest: Codable, Equatable, Sendable {
    public let domains: [BlockedDomain]
    public let requestedAt: Date

    public init(domains: [BlockedDomain], requestedAt: Date) {
        self.domains = domains
        self.requestedAt = requestedAt
    }
}

public struct SessionState: Codable, Equatable, Sendable {
    public let domains: [BlockedDomain]
    public let startedAt: Date
    public let endsAt: Date

    public init(domains: [BlockedDomain], startedAt: Date, endsAt: Date) {
        self.domains = domains
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    public var isActive: Bool {
        isActive(at: Date())
    }

    public var remaining: TimeInterval {
        remaining(at: Date())
    }

    public func isActive(at date: Date) -> Bool {
        date >= startedAt && date < endsAt
    }

    public func remaining(at date: Date) -> TimeInterval {
        let duration = max(0, endsAt.timeIntervalSince(startedAt))
        return max(0, min(duration, endsAt.timeIntervalSince(date)))
    }
}
