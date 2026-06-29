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
        XCTAssertNil(session.selectedBodyHighlightRange(textLength: "alpha".utf16.count))
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
        XCTAssertNil(session.selectedBodyHighlightRange(textLength: "alpha".utf16.count))
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
            debouncedQuery: initial.debouncedQuery,
            matches: initial.matches,
            selectedMatchID: selectedID
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
            debouncedQuery: "alpha",
            matches: [],
            selectedMatchID: "stale"
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
            debouncedQuery: "alpha",
            matches: [],
            selectedMatchID: "body-200-5"
        )

        let rebuilt = stale.rebuilt(
            bodyText: "alpha beta",
            pinnedTexts: [],
            query: "alpha"
        )

        XCTAssertEqual(rebuilt.selectedMatchID, rebuilt.matches.first?.id)
        XCTAssertEqual(
            rebuilt.selectedBodyHighlightRange(textLength: "alpha beta".utf16.count),
            NSRange(location: 0, length: 5)
        )
    }

    func testNextNavigationWraps() {
        let session = EditorSearchSession().rebuilt(
            bodyText: "alpha beta alpha gamma alpha",
            pinnedTexts: [],
            query: "alpha"
        )

        let selectedLast = EditorSearchSession(
            debouncedQuery: session.debouncedQuery,
            matches: session.matches,
            selectedMatchID: session.matches[2].id
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

        XCTAssertEqual(
            session.selectedBodyHighlightRange(textLength: "Body alpha detail".utf16.count),
            NSRange(location: 5, length: 5)
        )
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
        XCTAssertNil(session.selectedBodyHighlightRange(textLength: "Body alpha detail".utf16.count))
    }

    func testSummaryTextCompatibility() {
        let session = EditorSearchSession().rebuilt(
            bodyText: "alpha beta alpha",
            pinnedTexts: [],
            query: "alpha"
        )
        let countOnly = EditorSearchSession(
            debouncedQuery: session.debouncedQuery,
            matches: session.matches,
            selectedMatchID: nil
        )

        XCTAssertEqual(EditorSearchSession().summaryText, "0")
        XCTAssertEqual(countOnly.summaryText, "2")
        XCTAssertEqual(session.summaryText, "1 of 2")
        XCTAssertEqual(session.selectingNext().summaryText, "2 of 2")
    }
}
