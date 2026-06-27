import Foundation

enum NoteSearchRegion: Equatable {
    case pinnedText(id: UUID)
    case body
}

struct NoteSearchMatch: Identifiable, Equatable {
    let id: String
    let region: NoteSearchRegion
    let plainTextRange: Range<String.Index>
    let nsRangeInRenderedText: NSRange?
    let previewText: String
}

struct NoteSearchPinnedText {
    let id: UUID
    let text: String
}

enum EditorSearchMatchResolver {
    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(
        in bodyText: String,
        pinnedTexts: [NoteSearchPinnedText],
        query: String
    ) -> [NoteSearchMatch] {
        let trimmedQuery = normalizedQuery(query)
        guard !trimmedQuery.isEmpty else { return [] }

        let pinnedMatches = pinnedTexts.flatMap { pinnedText in
            matches(
                in: pinnedText.text,
                query: trimmedQuery,
                region: .pinnedText(id: pinnedText.id),
                idPrefix: "pinned-\(pinnedText.id.uuidString)",
                includesRenderedRange: false
            )
        }

        let bodyMatches = matches(
            in: bodyText,
            query: trimmedQuery,
            region: .body,
            idPrefix: "body",
            includesRenderedRange: true
        )

        return pinnedMatches + bodyMatches
    }

    static func resolvedSelectedMatchID(in matches: [NoteSearchMatch], selectedMatchID: String?) -> String? {
        guard !matches.isEmpty else { return nil }
        if let selectedMatchID,
           matches.contains(where: { $0.id == selectedMatchID }) {
            return selectedMatchID
        }

        return matches.first?.id
    }

    static func resolvedSelectedMatch(in matches: [NoteSearchMatch], selectedMatchID: String?) -> NoteSearchMatch? {
        guard let selectedMatchID else { return nil }
        return matches.first { $0.id == selectedMatchID }
    }

    static func nextMatchIndex(in matches: [NoteSearchMatch], selectedMatchID: String?) -> Int? {
        matchIndex(in: matches, selectedMatchID: selectedMatchID, movingBy: 1)
    }

    static func previousMatchIndex(in matches: [NoteSearchMatch], selectedMatchID: String?) -> Int? {
        matchIndex(in: matches, selectedMatchID: selectedMatchID, movingBy: -1)
    }

    static func bodyRange(for match: NoteSearchMatch?, textLength: Int) -> NSRange? {
        guard case .body = match?.region,
              let range = match?.nsRangeInRenderedText,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textLength else {
            return nil
        }

        return range
    }

    private static func matchIndex(
        in matches: [NoteSearchMatch],
        selectedMatchID: String?,
        movingBy delta: Int
    ) -> Int? {
        guard !matches.isEmpty else { return nil }
        let currentIndex = selectedMatchID
            .flatMap { selectedID in matches.firstIndex { $0.id == selectedID } }
            ?? (delta > 0 ? -1 : 0)
        return (currentIndex + delta + matches.count) % matches.count
    }

    private static func matches(
        in text: String,
        query: String,
        region: NoteSearchRegion,
        idPrefix: String,
        includesRenderedRange: Bool
    ) -> [NoteSearchMatch] {
        var results: [NoteSearchMatch] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let range = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            let nsRange = NSRange(range, in: text)
            // Stable IDs let the editor preserve selection when a debounce refresh returns the same match set.
            results.append(NoteSearchMatch(
                id: "\(idPrefix)-\(nsRange.location)-\(nsRange.length)",
                region: region,
                plainTextRange: range,
                nsRangeInRenderedText: includesRenderedRange ? nsRange : nil,
                previewText: preview(in: text, matchRange: range)
            ))

            searchStart = range.upperBound < text.endIndex
                ? text.index(after: range.lowerBound)
                : text.endIndex
        }

        return results
    }

    private static func preview(in text: String, matchRange: Range<String.Index>) -> String {
        let contextLength = 32
        let lower = text.index(
            matchRange.lowerBound,
            offsetBy: -contextLength,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let upper = text.index(
            matchRange.upperBound,
            offsetBy: contextLength,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        return String(text[lower..<upper])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
