import XCTest
@testable import ProcrastinationBlockerCore

final class DomainTests: XCTestCase {
    func testSessionDurationsExposeOnlyAllowedOptions() {
        XCTAssertEqual(SessionDuration.allCases.map(\.minutes), [30, 60, 90, 120])
        XCTAssertEqual(SessionDuration.allCases.map(\.seconds), [1_800, 3_600, 5_400, 7_200])
        XCTAssertEqual(
            SessionDuration.allCases.map(\.displayName),
            ["30 minutes", "60 minutes", "90 minutes", "120 minutes"]
        )
    }

    func testSessionDurationAcceptsOnlyAllowedSeconds() {
        for duration in SessionDuration.allCases {
            XCTAssertEqual(SessionDuration(seconds: duration.seconds), duration)
        }

        for seconds in [-1, 0, 60, 1_799, 2_700, 7_201, 10_800] {
            XCTAssertNil(SessionDuration(seconds: seconds))
        }
    }

    func testDomainAcceptsAndNormalizesWebsiteInputs() throws {
        let examples = [
            ("x.com", "x.com"),
            ("X.COM", "x.com"),
            ("https://www.Example.COM/path/to/page?query=yes#section", "example.com"),
            ("http://news.example.com./article", "news.example.com"),
            ("www.youtube.com/watch?v=123", "youtube.com"),
        ]

        for (input, expected) in examples {
            XCTAssertEqual(try BlockedDomain(input).value, expected)
            XCTAssertEqual(try BlockedDomain.normalize(input), expected)
        }
    }

    func testDomainRejectsUnsafeOrInvalidHostnames() {
        let invalidInputs = [
            "",
            " x.com",
            "x.com ",
            "x .com",
            "x.com:443",
            "https://x.com:443/path",
            "https://user@x.com",
            "ftp://x.com",
            "localhost",
            "127.0.0.1",
            "x..com",
            "-x.com",
            "x-.com",
            "x_example.com",
            "x.123",
            "www.",
        ]

        for input in invalidInputs {
            XCTAssertThrowsError(try BlockedDomain(input), "Expected to reject \(input)")
        }
    }

    func testBlockedDomainCodableUsesAValidatedString() throws {
        let domain = try BlockedDomain("https://www.X.com/path")
        let data = try JSONEncoder().encode(domain)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"x.com\"")
        XCTAssertEqual(try JSONDecoder().decode(BlockedDomain.self, from: data), domain)
        XCTAssertThrowsError(
            try JSONDecoder().decode(BlockedDomain.self, from: Data("\"x.com:443\"".utf8))
        )
    }

    func testSessionRequestRoundTripsDomainsAndRequestedAt() throws {
        let request = SessionRequest(
            domains: [try BlockedDomain("x.com"), try BlockedDomain("youtube.com")],
            requestedAt: Date(timeIntervalSinceReferenceDate: 1_234)
        )

        let decoded = try JSONDecoder().decode(
            SessionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
    }

    func testSessionStateTimingIsDeterministicAtBoundaries() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let endsAt = startedAt.addingTimeInterval(1_800)
        let state = SessionState(
            domains: [try BlockedDomain("x.com")],
            startedAt: startedAt,
            endsAt: endsAt
        )

        XCTAssertFalse(state.isActive(at: startedAt.addingTimeInterval(-1)))
        XCTAssertEqual(state.remaining(at: startedAt.addingTimeInterval(-1)), 1_800)
        XCTAssertTrue(state.isActive(at: startedAt))
        XCTAssertEqual(state.remaining(at: startedAt.addingTimeInterval(300)), 1_500)
        XCTAssertFalse(state.isActive(at: endsAt))
        XCTAssertEqual(state.remaining(at: endsAt), 0)

        let decoded = try JSONDecoder().decode(
            SessionState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
    }
}
