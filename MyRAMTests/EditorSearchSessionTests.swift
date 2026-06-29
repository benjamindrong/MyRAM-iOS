import XCTest
@testable import MyRAM

final class EditorSearchSessionTests: XCTestCase {
    func testRebuiltSessionBuildsExpectedMatches() {
        let pinnedID = UUID()

        let session = EditorSearchSession().rebuilt(
            bodyText: "Body alpha detail",
            pinnedTexts: [NoteSearchPinnedText(id: pinnedID, text: "Pinned alpha")],
            query: "alpha"
        )

        XCTAssertEqual(session.query, "alpha")
        XCTAssertEqual(session.debouncedQuery, "alpha")
        XCTAssertEqual(session.matches.map(\.region), [.pinnedText(id: pinnedID), .body])
        XCTAssertEqual(session.selectedMatchID, session.matches.first?.id)
    }

    func testEmptyQueryClearsMatchesAndSelectedMatch() {
        let populated = EditorSearchSession().rebuilt(
            bodyText: "alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        let session = populated.rebuilt(
            bodyText: "alpha",
            pinnedTexts: [],
            query: "  \n"
        )

        XCTAssertEqual(session.matches, [])
        XCTAssertNil(session.selectedMatchID)
        XCTAssertNil(session.selectedBodyHighlightRange)
        XCTAssertEqual(session.summaryText, "0")
    }

    func testNoMatchQueryClearsSelectedMatchAndHighlightTarget() {
        let populated = EditorSearchSession().rebuilt(
            bodyText: "alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        let session = populated.rebuilt(
            bodyText: "alpha",
            pinnedTexts: [],
            query: "missing"
        )

        XCTAssertEqual(session.matches, [])
        XCTAssertNil(session.selectedMatchID)
        XCTAssertNil(session.selectedBodyHighlightRange)
        XCTAssertNil(session.selectedPinnedTextID)
        XCTAssertEqual(session.summaryText, "0")
    }

    func testRebuiltSessionPreservesValidSelectedMatch() {
        let initial = EditorSearchSession().rebuilt(
            bodyText: "alpha beta alpha",
            pinnedTexts: [],
            query: "alpha"
        )
        let selectedID = initial.matches[1].id
        let selected = EditorSearchSession(
            query: initial.query,
            debouncedQuery: initial.debouncedQuery,
            matches: initial.matches,
            selectedMatchID: selectedID,
            bodyTextLength: "alpha beta alpha".utf16.count
        )

        let rebuilt = selected.rebuilt(
            bodyText: "alpha beta alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(rebuilt.selectedMatchID, selectedID)
    }

    func testRebuiltSessionFallsBackFromStaleSelectedMatch() {
        let stale = EditorSearchSession(
            query: "alpha",
            debouncedQuery: "alpha",
            matches: [],
            selectedMatchID: "stale",
            bodyTextLength: 0
        )

        let rebuilt = stale.rebuilt(
            bodyText: "alpha beta alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(rebuilt.selectedMatchID, rebuilt.matches.first?.id)
    }

    func testOutOfBoundsSelectedMatchFallsBackCleanly() {
        let stale = EditorSearchSession(
            query: "alpha",
            debouncedQuery: "alpha",
            matches: [],
            selectedMatchID: "body-200-5",
            bodyTextLength: 0
        )

        let rebuilt = stale.rebuilt(
            bodyText: "alpha beta",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(rebuilt.selectedMatchID, rebuilt.matches.first?.id)
        XCTAssertEqual(rebuilt.selectedBodyHighlightRange, NSRange(location: 0, length: 5))
    }

    func testNextNavigationWraps() {
        let session = EditorSearchSession().rebuilt(
            bodyText: "alpha beta alpha gamma alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        let selectedLast = EditorSearchSession(
            query: session.query,
            debouncedQuery: session.debouncedQuery,
            matches: session.matches,
            selectedMatchID: session.matches[2].id,
            bodyTextLength: "alpha beta alpha gamma alpha".utf16.count
        )

        XCTAssertEqual(selectedLast.selectingNext().selectedMatchID, session.matches[0].id)
    }

    func testPreviousNavigationWraps() {
        let session = EditorSearchSession().rebuilt(
            bodyText: "alpha beta alpha gamma alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(session.selectingPrevious().selectedMatchID, session.matches[2].id)
    }

    func testSelectedBodyMatchEmitsBodyHighlightRange() {
        let session = EditorSearchSession().rebuilt(
            bodyText: "Body alpha detail",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(session.selectedBodyHighlightRange, NSRange(location: 5, length: 5))
        XCTAssertNil(session.selectedPinnedTextID)
    }

    func testSelectedPinnedMatchEmitsPinnedTextIDAndNoBodyHighlightRange() {
        let pinnedID = UUID()

        let session = EditorSearchSession().rebuilt(
            bodyText: "Body alpha detail",
            pinnedTexts: [NoteSearchPinnedText(id: pinnedID, text: "Pinned alpha")],
            query: "alpha"
        )

        XCTAssertEqual(session.selectedPinnedTextID, pinnedID)
        XCTAssertNil(session.selectedBodyHighlightRange)
    }

    func testSummaryTextCompatibility() {
        let session = EditorSearchSession().rebuilt(
            bodyText: "alpha beta alpha",
            pinnedTexts: [],
            query: "alpha"
        )
        let countOnly = EditorSearchSession(
            query: session.query,
            debouncedQuery: session.debouncedQuery,
            matches: session.matches,
            selectedMatchID: nil,
            bodyTextLength: "alpha beta alpha".utf16.count
        )

        XCTAssertEqual(EditorSearchSession().summaryText, "0")
        XCTAssertEqual(countOnly.summaryText, "2")
        XCTAssertEqual(session.summaryText, "1 of 2")
        XCTAssertEqual(session.selectingNext().summaryText, "2 of 2")
    }
}
