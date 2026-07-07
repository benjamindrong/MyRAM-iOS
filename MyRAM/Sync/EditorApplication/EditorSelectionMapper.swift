import Foundation

enum EditorSelectionMapper {
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
            ).editorClamped(toLength: resultingTextLength)
        }

        if insertionOffset < currentEnd {
            return NSRange(
                location: current.location,
                length: current.length + insertedUTF16Length
            ).editorClamped(toLength: resultingTextLength)
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
            ).editorClamped(toLength: resultingTextLength)
        }

        if deletedRange.location >= currentEnd {
            return clamped(current, toLength: resultingTextLength)
        }

        if current.length == 0 {
            return NSRange(location: deletedRange.location, length: 0)
                .editorClamped(toLength: resultingTextLength)
        }

        let overlapStart = max(current.location, deletedRange.location)
        let overlapEnd = min(currentEnd, deletedEnd)
        let removedFromSelection = max(0, overlapEnd - overlapStart)
        let adjustedLocation: Int
        if current.location >= deletedRange.location && current.location < deletedEnd {
            adjustedLocation = deletedRange.location
        } else {
            let deletedBeforeSelection = max(0, min(deletedEnd, current.location) - deletedRange.location)
            adjustedLocation = current.location - deletedBeforeSelection
        }
        let adjustedLength = max(0, current.length - removedFromSelection)

        return NSRange(location: adjustedLocation, length: adjustedLength)
            .editorClamped(toLength: resultingTextLength)
    }

    private static func clamped(_ range: NSRange, toLength length: Int) -> NSRange {
        range.editorClamped(toLength: length)
    }
}

extension NSRange {
    func editorClamped(toLength length: Int) -> NSRange {
        let safeTextLength = max(length, 0)
        let safeLocation = min(max(location, 0), safeTextLength)
        let maxLength = max(safeTextLength - safeLocation, 0)
        return NSRange(location: safeLocation, length: min(self.length, maxLength))
    }
}
