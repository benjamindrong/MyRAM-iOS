import Foundation

enum EditorSelectionRangeResolver {
    static func clampedSelectionRange(_ range: NSRange, textLength: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: textLength, length: 0)
        }

        let safeLocation = min(max(range.location, 0), textLength)
        let safeLength = min(range.length, max(textLength - safeLocation, 0))
        return NSRange(location: safeLocation, length: safeLength)
    }

    /// Mirrors the historical checklist-rendering selection restore clamp.
    /// Unlike `clampedSelectionRange`, this intentionally does not normalize
    /// `NSNotFound` or negative locations. Do not merge these paths without an
    /// explicit behavior decision.
    static func clampedRenderedSelectionRange(_ range: NSRange, textLength: Int) -> NSRange {
        let safeLocation = min(range.location, textLength)
        let safeLength = min(range.length, textLength - safeLocation)
        return NSRange(location: safeLocation, length: safeLength)
    }

    static func clampedCaretLocation(_ location: Int, textLength: Int) -> Int {
        min(max(location, 0), textLength)
    }

    static func isValidRange(_ range: NSRange, textLength: Int) -> Bool {
        guard textLength >= 0,
              range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0,
              range.location <= textLength else {
            return false
        }

        return range.length <= textLength - range.location
    }

    static func hasPositiveLengthResolvedRange(_ range: NSRange, textLength: Int) -> Bool {
        range.length > 0 && isValidRange(range, textLength: textLength)
    }
}
