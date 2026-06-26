import UIKit

enum EditorTextPlacementResolver {
    static func caretRange(forTapLocation point: CGPoint, in textView: UITextView) -> NSRange {
        let textLength = textView.textStorage.length
        guard textLength > 0 else { return NSRange(location: 0, length: 0) }

        textView.layoutManager.ensureLayout(for: textView.textContainer)

        var location = point
        location.x -= textView.textContainerInset.left
        location.y -= textView.textContainerInset.top
        location.x -= textView.textContainer.lineFragmentPadding

        let characterIndex = textView.layoutManager.characterIndex(
            for: location,
            in: textView.textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return NSRange(location: min(max(characterIndex, 0), textLength), length: 0)
    }
}
