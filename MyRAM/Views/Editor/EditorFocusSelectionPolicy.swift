import Foundation

enum EditorFocusSelectionPolicy {
    enum FocusRestoreDecision: Equatable {
        case restoreSessionFallback(NSRange)
        case restoreFocusAcquisition(NSRange)
        case acceptCurrent
    }

    static func focusRestoreDecision(
        currentRange: NSRange,
        focusAcquisitionRange: NSRange?,
        sessionRange: NSRange?,
        textLength: Int
    ) -> FocusRestoreDecision {
        if currentRange.location == NSNotFound,
           let sessionRange,
           EditorSelectionRangeResolver.isValidRange(sessionRange, textLength: textLength) {
            return .restoreSessionFallback(sessionRange)
        } else if shouldRestoreFocusAcquisitionRange(
            currentRange,
            focusAcquisitionRange: focusAcquisitionRange,
            textLength: textLength
        ), let focusAcquisitionRange {
            return .restoreFocusAcquisition(focusAcquisitionRange)
        } else {
            return .acceptCurrent
        }
    }

    static func cachedSelectionRange(
        currentRange: NSRange,
        isFirstResponder: Bool,
        cachedRange: NSRange?,
        textLength: Int
    ) -> NSRange? {
        if currentRange.length > 0 || isFirstResponder {
            return currentRange
        }

        guard let cachedRange,
              EditorSelectionRangeResolver.hasPositiveLengthResolvedRange(cachedRange, textLength: textLength) else {
            return nil
        }

        return cachedRange
    }

    static func shouldCacheSelection(
        range: NSRange,
        isFirstResponder: Bool
    ) -> Bool {
        range.length > 0 || isFirstResponder
    }

    private static func shouldRestoreFocusAcquisitionRange(
        _ currentRange: NSRange,
        focusAcquisitionRange: NSRange?,
        textLength: Int
    ) -> Bool {
        guard currentRange.location == textLength,
              textLength > 0,
              let focusAcquisitionRange,
              EditorSelectionRangeResolver.isValidRange(focusAcquisitionRange, textLength: textLength),
              focusAcquisitionRange.location != textLength else {
            return false
        }

        return true
    }
}
