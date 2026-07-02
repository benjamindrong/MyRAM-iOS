#if os(macOS)
import Foundation

enum MacEditorSelectionMapper {
    static func selectionAfterInsertion(
        current: NSRange,
        insertionOffset: Int,
        insertedUTF16Length: Int,
        resultingTextLength: Int
    ) -> NSRange {
        guard insertedUTF16Length > 0 else {
            return clamped(current, toLength: resultingTextLength)
        }

        let currentEnd = NSMaxRange(current)
        if insertionOffset <= current.location {
            return NSRange(
                location: current.location + insertedUTF16Length,
                length: current.length
            ).clampedForSelectionMapper(toLength: resultingTextLength)
        }

        if insertionOffset < currentEnd {
            return NSRange(
                location: current.location,
                length: current.length + insertedUTF16Length
            ).clampedForSelectionMapper(toLength: resultingTextLength)
        }

        return clamped(current, toLength: resultingTextLength)
    }

    static func selectionAfterDeletion(
        current: NSRange,
        deletedRange: NSRange,
        resultingTextLength: Int
    ) -> NSRange {
        guard deletedRange.length > 0 else {
            return clamped(current, toLength: resultingTextLength)
        }

        let currentEnd = NSMaxRange(current)
        let deletedEnd = NSMaxRange(deletedRange)

        if deletedEnd <= current.location {
            return NSRange(
                location: current.location - deletedRange.length,
                length: current.length
            ).clampedForSelectionMapper(toLength: resultingTextLength)
        }

        if deletedRange.location >= currentEnd {
            return clamped(current, toLength: resultingTextLength)
        }

        if current.length == 0 {
            return NSRange(location: deletedRange.location, length: 0)
                .clampedForSelectionMapper(toLength: resultingTextLength)
        }

        let survivingStart = min(current.location, deletedRange.location)
        let overlapStart = max(current.location, deletedRange.location)
        let overlapEnd = min(currentEnd, deletedEnd)
        let removedFromSelection = max(0, overlapEnd - overlapStart)
        let deletedBeforeSelection = max(0, min(deletedEnd, current.location) - deletedRange.location)
        let adjustedLocation = max(0, survivingStart - deletedBeforeSelection)
        let adjustedLength = max(0, current.length - removedFromSelection)

        return NSRange(location: adjustedLocation, length: adjustedLength)
            .clampedForSelectionMapper(toLength: resultingTextLength)
    }

    private static func clamped(_ range: NSRange, toLength length: Int) -> NSRange {
        range.clampedForSelectionMapper(toLength: length)
    }
}

private extension NSRange {
    func clampedForSelectionMapper(toLength length: Int) -> NSRange {
        let safeLocation = min(max(location, 0), max(length, 0))
        let maxLength = max(length - safeLocation, 0)
        return NSRange(location: safeLocation, length: min(self.length, maxLength))
    }
}
#endif
