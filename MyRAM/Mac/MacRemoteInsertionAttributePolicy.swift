#if os(macOS)
import AppKit

enum MacRemoteInsertionAttributePolicy {
    static func attributesForRemoteInsertion(
        in attributedString: NSAttributedString,
        at offset: Int,
        defaultAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        guard attributedString.length > 0 else {
            return defaultAttributes
        }

        if offset > 0 {
            return attributedString.attributes(
                at: min(offset - 1, attributedString.length - 1),
                effectiveRange: nil
            )
        }

        return attributedString.attributes(at: 0, effectiveRange: nil)
    }
}
#endif
