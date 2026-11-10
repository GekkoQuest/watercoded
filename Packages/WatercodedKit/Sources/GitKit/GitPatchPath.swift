import Foundation

/// Git's patch headers use C quoting for tabs, newlines and quotes, even with core.quotepath=off.
enum GitPatchPath {
    static func decode(_ text: String) -> String {
        guard text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        let bytes = Array(text.utf8.dropFirst().dropLast())
        var result: [UInt8] = []
        var index = 0
        let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13]
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            guard byte == 92, index < bytes.count else {
                result.append(byte)
                continue
            }
            let escaped = bytes[index]
            index += 1
            if (48 ... 55).contains(escaped) {
                var value = Int(escaped - 48)
                for _ in 0 ..< 2 where index < bytes.count && (48 ... 55).contains(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - 48)
                    index += 1
                }
                result.append(UInt8(truncatingIfNeeded: value))
            } else {
                result.append(escapes[escaped] ?? escaped)
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    static func encode(_ path: String) -> String {
        guard path.utf8.contains(where: { $0 <= 32 || $0 == 34 || $0 == 92 || $0 == 127 }) else { return path }
        let escaped = path.utf8.map { byte -> String in
            switch byte {
            case 34: return "\\\""
            case 92: return "\\\\"
            case 0 ... 32, 127 ... 255: return String(format: "\\%03o", Int(byte))
            default: return String(UnicodeScalar(byte))
            }
        }.joined()
        return "\"" + escaped + "\""
    }

    /// Finds the second path in `diff --git`, where unquoted paths may contain spaces.
    static func destination(in header: String) -> String {
        if header.hasPrefix("\"") {
            var escaped = false
            for index in header.indices.dropFirst() {
                let character = header[index]
                if character == "\"", !escaped {
                    return decode(String(header[header.index(after: index)...].drop(while: { $0 == " " })))
                }
                escaped = character == "\\" && !escaped
            }
        }
        // Without a rename both names are identical. Use that to disambiguate spaces inside a name.
        for range in header.ranges(of: " b/") {
            let source = String(header[..<range.lowerBound].dropFirst(2))
            let destination = String(header[range.upperBound...])
            if source == destination {
                return "b/" + destination
            }
        }
        if let range = header.range(of: " \"b/") {
            return decode(String(header[header.index(after: range.lowerBound)...]))
        }
        return header.range(of: " b/").map { String(header[header.index(after: $0.lowerBound)...]) } ?? header
    }
}
