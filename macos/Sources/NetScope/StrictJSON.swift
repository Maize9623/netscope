import Foundation

/// JSONSerialization collapses duplicate keys. Validate the original bytes first so
/// conflicting evidence cannot be silently replaced, including escaped key spellings.
enum StrictJSON {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        if parser.bytes.starts(with: [0xef, 0xbb, 0xbf]) { parser.index = 3 }
        try parser.value(depth: 0)
        parser.whitespace()
        guard parser.index == parser.bytes.count else { throw CodexClientError.invalidReport }
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() { while index < bytes.count && [UInt8(0x20),0x09,0x0a,0x0d].contains(bytes[index]) { index += 1 } }
        mutating func value(depth: Int) throws {
            guard depth < 64 else { throw CodexClientError.invalidReport }
            whitespace()
            guard index < bytes.count else { throw CodexClientError.invalidReport }
            switch bytes[index] {
            case 0x7b: try object(depth: depth + 1)
            case 0x5b: try array(depth: depth + 1)
            case 0x22: _ = try string()
            case 0x74: try literal([0x74,0x72,0x75,0x65])
            case 0x66: try literal([0x66,0x61,0x6c,0x73,0x65])
            case 0x6e: try literal([0x6e,0x75,0x6c,0x6c])
            case 0x2d,0x30...0x39: try number()
            default: throw CodexClientError.invalidReport
            }
        }
        mutating func object(depth: Int) throws {
            index += 1; whitespace()
            if consume(0x7d) { return }
            var keys = Set<String>()
            while true {
                whitespace()
                let key = try string()
                guard keys.insert(key).inserted else { throw CodexClientError.invalidReport }
                whitespace(); guard consume(0x3a) else { throw CodexClientError.invalidReport }
                try value(depth: depth); whitespace()
                if consume(0x7d) { return }
                guard consume(0x2c) else { throw CodexClientError.invalidReport }
            }
        }
        mutating func array(depth: Int) throws {
            index += 1; whitespace()
            if consume(0x5d) { return }
            while true {
                try value(depth: depth); whitespace()
                if consume(0x5d) { return }
                guard consume(0x2c) else { throw CodexClientError.invalidReport }
            }
        }
        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == 0x22 else { throw CodexClientError.invalidReport }
            let start = index; index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    guard let result = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else { throw CodexClientError.invalidReport }
                    return result
                }
                guard byte >= 0x20 else { throw CodexClientError.invalidReport }
                if byte == 0x5c { index += 2 } else { index += 1 }
            }
            throw CodexClientError.invalidReport
        }
        mutating func number() throws {
            _ = consume(0x2d)
            if !consume(0x30) {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else { throw CodexClientError.invalidReport }
                digits()
            }
            if consume(0x2e) {
                let start = index; digits()
                guard index > start else { throw CodexClientError.invalidReport }
            }
            if consume(0x65) || consume(0x45) {
                if !consume(0x2b) { _ = consume(0x2d) }
                let start = index; digits()
                guard index > start else { throw CodexClientError.invalidReport }
            }
        }
        mutating func digits() { while index < bytes.count && (0x30...0x39).contains(bytes[index]) { index += 1 } }
        mutating func literal(_ expected: [UInt8]) throws {
            guard index + expected.count <= bytes.count, Array(bytes[index..<(index + expected.count)]) == expected else { throw CodexClientError.invalidReport }
            index += expected.count
        }
        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }
    }
}
