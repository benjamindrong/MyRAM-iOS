import UIKit

enum EditorPasteFormatter {
    static func attributedString(
        matchingDestinationFormattingFor text: String,
        typingAttributes: [NSAttributedString.Key: Any],
        defaultAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        var attributes = defaultAttributes
        typingAttributes.forEach { key, value in
            attributes[key] = value
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
