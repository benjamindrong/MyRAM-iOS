import Foundation

extension String {
    func syncBatchClampedUTF16Offset(_ offset: Int) -> Int {
        min(max(offset, 0), utf16.count)
    }

    func syncBatchSafeInsertionOffset(fallingForwardFrom offset: Int) -> Int {
        var candidate = syncBatchClampedUTF16Offset(offset)
        while candidate < utf16.count, syncBatchSafeUTF16Range(location: candidate, length: 0) == nil {
            candidate += 1
        }
        return candidate
    }

    func syncBatchInserting(_ text: String, atUTF16Offset offset: Int) -> String {
        let nsString = self as NSString
        let range = NSRange(location: syncBatchClampedUTF16Offset(offset), length: 0)
        return nsString.replacingCharacters(in: range, with: text)
    }

    func syncBatchSafeUTF16Range(location: Int, length: Int) -> NSRange? {
        guard location >= 0, length >= 0, location + length <= utf16.count else {
            return nil
        }

        guard syncBatchIsValidUTF16Boundary(location),
              syncBatchIsValidUTF16Boundary(location + length) else {
            return nil
        }

        let range = NSRange(location: location, length: length)
        guard Range(range, in: self) != nil else { return nil }
        return range
    }

    private func syncBatchIsValidUTF16Boundary(_ offset: Int) -> Bool {
        guard offset >= 0, offset <= utf16.count else { return false }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: self) != nil
    }
}
