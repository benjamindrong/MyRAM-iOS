import Foundation

enum RTFCoding {
    static func encode(_ attributedText: NSAttributedString) -> Data? {
        guard attributedText.length > 0 else { return nil }

        return try? attributedText.data(
            from: NSRange(location: 0, length: attributedText.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf
            ]
        )
    }
}
