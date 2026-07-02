#if os(macOS)
import Foundation

extension NSRange {
    func macClamped(toLength length: Int) -> NSRange {
        let safeTextLength = max(length, 0)
        let safeLocation = min(max(location, 0), safeTextLength)
        let maxLength = max(safeTextLength - safeLocation, 0)
        return NSRange(location: safeLocation, length: min(self.length, maxLength))
    }
}
#endif
