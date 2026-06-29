import Foundation

struct EditorSearchSession: Equatable {
    var debouncedQuery: String = ""
    var matches: [NoteSearchMatch] = []
    var selectedMatchID: String?

    init(
        debouncedQuery: String = "",
        matches: [NoteSearchMatch] = [],
        selectedMatchID: String? = nil
    ) {
        self.debouncedQuery = debouncedQuery
        self.matches = matches
        self.selectedMatchID = selectedMatchID
    }

    var selectedMatch: NoteSearchMatch? {
        EditorSearchMatchResolver.resolvedSelectedMatch(
            in: matches,
            selectedMatchID: selectedMatchID
        )
    }

    func selectedBodyHighlightRange(textLength: Int) -> NSRange? {
        EditorSearchMatchResolver.bodyRange(
            for: selectedMatch,
            textLength: textLength
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
            debouncedQuery: query,
            matches: rebuiltMatches,
            selectedMatchID: EditorSearchMatchResolver.resolvedSelectedMatchID(
                in: rebuiltMatches,
                selectedMatchID: selectedMatchID
            )
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
