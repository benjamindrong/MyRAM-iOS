import Foundation

struct EditorSearchSession: Equatable {
    var query: String = ""
    var debouncedQuery: String = ""
    var matches: [NoteSearchMatch] = []
    var selectedMatchID: String?
    private var bodyTextLength = 0

    init(
        query: String = "",
        debouncedQuery: String = "",
        matches: [NoteSearchMatch] = [],
        selectedMatchID: String? = nil,
        bodyTextLength: Int = 0
    ) {
        self.query = query
        self.debouncedQuery = debouncedQuery
        self.matches = matches
        self.selectedMatchID = selectedMatchID
        self.bodyTextLength = bodyTextLength
    }

    var selectedMatch: NoteSearchMatch? {
        EditorSearchMatchResolver.resolvedSelectedMatch(
            in: matches,
            selectedMatchID: selectedMatchID
        )
    }

    var selectedBodyHighlightRange: NSRange? {
        EditorSearchMatchResolver.bodyRange(
            for: selectedMatch,
            textLength: bodyTextLength
        )
    }

    var selectedPinnedTextID: UUID? {
        guard case let .pinnedText(id) = selectedMatch?.region else { return nil }
        return id
    }

    var summaryText: String {
        guard !EditorSearchMatchResolver.normalizedQuery(debouncedQuery).isEmpty else { return "0" }
        guard let selectedMatchID,
              let index = matches.firstIndex(where: { $0.id == selectedMatchID }) else {
            return matches.isEmpty ? "0" : "\(matches.count)"
        }
        return "\(index + 1) of \(matches.count)"
    }

    func updatingQuery(_ query: String) -> EditorSearchSession {
        var session = self
        session.query = query
        return session
    }

    func rebuilt(
        bodyText: String,
        pinnedTexts: [NoteSearchPinnedText],
        query: String
    ) -> EditorSearchSession {
        let rebuiltMatches = EditorSearchMatchResolver.matches(
            in: bodyText,
            pinnedTexts: pinnedTexts,
            query: query
        )
        return EditorSearchSession(
            query: query,
            debouncedQuery: query,
            matches: rebuiltMatches,
            selectedMatchID: EditorSearchMatchResolver.resolvedSelectedMatchID(
                in: rebuiltMatches,
                selectedMatchID: selectedMatchID
            ),
            bodyTextLength: bodyText.utf16.count
        )
    }

    func cleared() -> EditorSearchSession {
        EditorSearchSession()
    }

    func selectingNext() -> EditorSearchSession {
        selectingMatch(movingBy: 1)
    }

    func selectingPrevious() -> EditorSearchSession {
        selectingMatch(movingBy: -1)
    }

    func selectingFirstIfNeeded() -> EditorSearchSession {
        guard selectedMatchID == nil else { return self }
        var session = self
        session.selectedMatchID = EditorSearchMatchResolver.resolvedSelectedMatchID(
            in: matches,
            selectedMatchID: selectedMatchID
        )
        return session
    }

    private func selectingMatch(movingBy delta: Int) -> EditorSearchSession {
        guard let nextIndex = EditorSearchMatchResolver.matchIndex(
            in: matches,
            selectedMatchID: selectedMatchID,
            movingBy: delta
        ) else { return self }

        var session = self
        session.selectedMatchID = matches[nextIndex].id
        return session
    }
}
