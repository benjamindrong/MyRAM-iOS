import Foundation

enum RTFCoding {
    static func encode(_ attributedText: NSAttributedString) -> Data? {
        guard attributedText.length > 0 else { return nil }

        let cacheText = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: cacheText.length)
        cacheText.removeAttribute(.explicitStructuralFontSizeMilliPoints, range: fullRange)

        return try? cacheText.data(
            from: fullRange,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
        )
    }
}
