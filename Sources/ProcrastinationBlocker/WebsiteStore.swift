import Foundation
import ProcrastinationBlockerCore

@MainActor
final class WebsiteStore: ObservableObject {
    static let defaultDomainValues = [
        "x.com",
        "instagram.com",
        "linkedin.com",
        "youtube.com",
    ]

    @Published private(set) var domains: [BlockedDomain]

    private let defaults: UserDefaults
    private let storageKey = "BlockedDomains"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored = defaults.stringArray(forKey: storageKey)
        let source = stored?.isEmpty == false ? stored! : Self.defaultDomainValues
        domains = Self.validDomains(from: source)

        if domains.isEmpty {
            domains = Self.validDomains(from: Self.defaultDomainValues)
        }
        persist()
    }

    func add(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = try BlockedDomain(trimmed)
        guard !domains.contains(domain) else {
            throw WebsiteStoreError.duplicate(domain.value)
        }

        domains.append(domain)
        persist()
    }

    func remove(_ domain: BlockedDomain) throws {
        guard domains.count > 1 else {
            throw WebsiteStoreError.lastDomain
        }

        domains.removeAll { $0 == domain }
        persist()
    }

    func resetDefaults() {
        domains = Self.validDomains(from: Self.defaultDomainValues)
        persist()
    }

    private func persist() {
        defaults.set(domains.map(\.value), forKey: storageKey)
    }

    private static func validDomains(from values: [String]) -> [BlockedDomain] {
        var seen = Set<BlockedDomain>()
        return values.compactMap { value in
            guard let domain = try? BlockedDomain(value), seen.insert(domain).inserted else {
                return nil
            }
            return domain
        }
    }
}

enum WebsiteStoreError: LocalizedError {
    case duplicate(String)
    case lastDomain

    var errorDescription: String? {
        switch self {
        case .duplicate(let domain):
            return "\(domain) is already on the list."
        case .lastDomain:
            return "Keep at least one website on the list."
        }
    }
}
