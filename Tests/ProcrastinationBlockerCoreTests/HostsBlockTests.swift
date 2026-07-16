import XCTest
@testable import ProcrastinationBlockerCore

final class HostsBlockTests: XCTestCase {
    func testRenderPreservesUnrelatedLinesAndAddsSortedExactAndWWWEntries() throws {
        let original = "127.0.0.1\tlocalhost\n# custom spacing is preserved" + "   \n"
        let domains = [
            try BlockedDomain("youtube.com"),
            try BlockedDomain("x.com"),
            try BlockedDomain("www.x.com"),
        ]

        let rendered = try HostsBlock.render(original: original, domains: domains)

        XCTAssertEqual(
            rendered,
            """
            127.0.0.1\tlocalhost
            # custom spacing is preserved\("   ")
            # >>> procrastination blocker >>>
            0.0.0.0 x.com
            0.0.0.0 www.x.com
            0.0.0.0 youtube.com
            0.0.0.0 www.youtube.com
            # <<< procrastination blocker <<<

            """
        )
    }

    func testRenderReplacesOneManagedBlockInPlace() throws {
        let original = """
        before
        # >>> procrastination blocker >>>
        0.0.0.0 old.example.com
        # <<< procrastination blocker <<<
        after

        """

        let rendered = try HostsBlock.render(
            original: original,
            domains: [try BlockedDomain("x.com")]
        )

        XCTAssertEqual(
            rendered,
            """
            before
            # >>> procrastination blocker >>>
            0.0.0.0 x.com
            0.0.0.0 www.x.com
            # <<< procrastination blocker <<<
            after

            """
        )
    }

    func testEmptyDomainsRemoveOnlyTheManagedBlock() throws {
        let original = """
        127.0.0.1 localhost
        # >>> procrastination blocker >>>
        0.0.0.0 x.com
        0.0.0.0 www.x.com
        # <<< procrastination blocker <<<
        # keep this comment exactly

        """

        XCTAssertEqual(
            try HostsBlock.render(original: original, domains: []),
            "127.0.0.1 localhost\n# keep this comment exactly\n"
        )
    }

    func testEmptyDomainsLeaveAnUnmanagedFileUnchanged() throws {
        let originals = [
            "127.0.0.1 localhost\n# untouched\n",
            "127.0.0.1 localhost\n# no trailing newline",
            "127.0.0.1 localhost\r\n# windows line endings\r\n",
        ]

        for original in originals {
            XCTAssertEqual(try HostsBlock.render(original: original, domains: []), original)
        }
    }

    func testDuplicateMarkersFailClosed() throws {
        let original = """
        # >>> procrastination blocker >>>
        # >>> procrastination blocker >>>
        # <<< procrastination blocker <<<

        """

        XCTAssertThrowsError(try HostsBlock.render(original: original, domains: [])) { error in
            XCTAssertEqual(error as? HostsBlockError, .malformedMarkers)
        }
    }

    func testUnmatchedStartMarkerFailsWithoutReturningTruncatedContent() throws {
        let original = """
        line before
        # >>> procrastination blocker >>>
        line that must not be truncated

        """

        XCTAssertThrowsError(try HostsBlock.render(original: original, domains: [])) { error in
            XCTAssertEqual(error as? HostsBlockError, .malformedMarkers)
        }
    }

    func testUnmatchedEndAndReversedMarkersFailClosed() throws {
        let unmatchedEnd = "# <<< procrastination blocker <<<\nkeep\n"
        let reversed = """
        # <<< procrastination blocker <<<
        keep
        # >>> procrastination blocker >>>

        """

        for original in [unmatchedEnd, reversed] {
            XCTAssertThrowsError(try HostsBlock.render(original: original, domains: [])) { error in
                XCTAssertEqual(error as? HostsBlockError, .malformedMarkers)
            }
        }
    }
}
