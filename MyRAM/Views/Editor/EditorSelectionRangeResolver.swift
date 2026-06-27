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

    static func clampedRenderedSelectionRange(_ range: NSRange, textLength: Int) -> NSRange {
        let safeLocation = min(range.location, textLength)
        let safeLength = min(range.length, textLength - safeLocation)
        return NSRange(location: safeLocation, length: safeLength)
    }

    static func clampedCaretLocation(_ location: Int, textLength: Int) -> Int {
        min(max(location, 0), textLength)
    }

    static func isValidRange(_ range: NSRange, textLength: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && NSMaxRange(range) <= textLength
    }

    static func hasPositiveLengthWithinText(_ range: NSRange, textLength: Int) -> Bool {
        range.length > 0
            && range.location + range.length <= textLength
    }

    static func hasPositiveLengthResolvedRange(_ range: NSRange, textLength: Int) -> Bool {
        range.location != NSNotFound
            && range.length > 0
            && NSMaxRange(range) <= textLength
    }
}
