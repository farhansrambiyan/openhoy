import Foundation

/// Since macOS Ventura many rows in `message` leave `text` NULL and store the body
/// only in `attributedBody`, an `NSAttributedString` serialized with the legacy
/// `NSArchiver` "typedstream" format. `NSUnarchiver` raises Objective-C exceptions on
/// malformed input (which Swift can't catch), so we pull the string out by hand.
enum AttributedBodyDecoder {
    private static let markers = [Array("NSString".utf8), Array("NSMutableString".utf8)]

    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let markerEnd = markers.lazy.compactMap({ find($0, in: bytes) }).first else { return nil }

        // After the class name comes a short header, then '+' (0x2B) which
        // introduces the C string, followed by its length.
        var i = markerEnd
        let limit = min(bytes.count, markerEnd + 12)
        while i < limit, bytes[i] != 0x2B { i += 1 }
        guard i < limit else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        var length = 0
        switch bytes[i] {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
            i += 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24
            i += 5
        default:
            length = Int(bytes[i])
            i += 1
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(decoding: bytes[i..<(i + length)], as: UTF8.self)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        outer: for start in 0...(haystack.count - needle.count) {
            for (offset, byte) in needle.enumerated() where haystack[start + offset] != byte {
                continue outer
            }
            return start + needle.count
        }
        return nil
    }
}
