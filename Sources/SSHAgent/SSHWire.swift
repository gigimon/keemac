import Foundation

/// Reads the SSH binary encoding (RFC 4251): big-endian integers, length-prefixed strings, mpints.
struct SSHReader {
    enum Failure: Error {
        case truncated
    }

    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        offset = 0
    }

    var isAtEnd: Bool { offset >= data.count }
    var remaining: Data { data.subdata(in: offset..<data.count) }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else { throw Failure.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint32() throws -> UInt32 {
        let bytes = try fixed(4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func fixed(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw Failure.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func string() throws -> Data {
        try fixed(Int(try uint32()))
    }

    mutating func text() throws -> String {
        String(decoding: try string(), as: UTF8.self)
    }

    /// An mpint without its sign byte: the plain big-endian magnitude.
    mutating func mpint() throws -> Data {
        var value = try string()
        while value.first == 0 {
            value.removeFirst()
        }
        return value
    }
}

/// Writes the SSH binary encoding.
struct SSHWriter {
    private(set) var data = Data()

    mutating func byte(_ value: UInt8) {
        data.append(value)
    }

    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func raw(_ value: Data) {
        data.append(value)
    }

    mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) {
        string(Data(value.utf8))
    }

    /// An unsigned big-endian magnitude as an mpint (leading zero when the top bit is set).
    mutating func mpint(_ magnitude: Data) {
        var value = Data(magnitude.drop { $0 == 0 })
        if let first = value.first, first & 0x80 != 0 {
            value.insert(0, at: 0)
        }
        string(value)
    }
}

/// Just enough DER to read PEM private keys (PKCS#1, SEC1, PKCS#8) and to build a PKCS#1 key for Security.framework.
enum DER {
    struct Node {
        let tag: UInt8
        let content: Data

        func children() throws -> [Node] {
            var reader = DERReader(content)
            var nodes: [Node] = []
            while !reader.isAtEnd {
                nodes.append(try reader.node())
            }
            return nodes
        }

        /// INTEGER content without leading zero bytes.
        var unsignedInteger: Data {
            Data(content.drop { $0 == 0 })
        }
    }

    static func parse(_ data: Data) throws -> Node {
        var reader = DERReader(data)
        return try reader.node()
    }

    static func sequence(_ items: [Data]) -> Data {
        encode(tag: 0x30, content: items.reduce(Data(), +))
    }

    static func integer(_ magnitude: Data) -> Data {
        var value = Data(magnitude.drop { $0 == 0 })
        if value.isEmpty {
            value = Data([0])
        } else if let first = value.first, first & 0x80 != 0 {
            value.insert(0, at: 0)
        }
        return encode(tag: 0x02, content: value)
    }

    static func encode(tag: UInt8, content: Data) -> Data {
        var result = Data([tag])
        let count = content.count
        if count < 0x80 {
            result.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            result.append(0x80 | UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        result.append(content)
        return result
    }
}

private struct DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = Data(data)
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func node() throws -> DER.Node {
        guard offset + 2 <= data.count else { throw SSHReader.Failure.truncated }
        let tag = data[offset]
        var length = Int(data[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + count <= data.count else { throw SSHReader.Failure.truncated }
            length = data[offset..<offset + count].reduce(0) { ($0 << 8) | Int($1) }
            offset += count
        }
        guard offset + length <= data.count else { throw SSHReader.Failure.truncated }
        defer { offset += length }
        return DER.Node(tag: tag, content: data.subdata(in: offset..<offset + length))
    }
}

/// Unsigned big-endian arithmetic, only what RSA CRT parameters need (d mod (p − 1)).
enum BigUnsigned {
    static func subtractOne(_ value: Data) -> Data {
        var bytes = [UInt8](value)
        var index = bytes.count - 1
        while index >= 0 {
            if bytes[index] > 0 {
                bytes[index] -= 1
                break
            }
            bytes[index] = 0xFF
            index -= 1
        }
        return Data(bytes)
    }

    /// `value mod modulus` by shift-and-subtract; fast enough for 4096-bit keys.
    static func modulo(_ value: Data, _ modulus: Data) -> Data {
        let m = [UInt8](modulus.drop { $0 == 0 })
        guard !m.isEmpty else { return Data() }
        var remainder = [UInt8](repeating: 0, count: m.count + 1)
        let mPadded = [0] + m
        for byte in value {
            for bit in (0..<8).reversed() {
                // remainder = remainder * 2 + bit
                var carry = (byte >> UInt8(bit)) & 1
                for index in stride(from: remainder.count - 1, through: 0, by: -1) {
                    let shifted = UInt16(remainder[index]) << 1 | UInt16(carry)
                    remainder[index] = UInt8(shifted & 0xFF)
                    carry = UInt8(shifted >> 8)
                }
                if !lessThan(remainder, mPadded) {
                    subtract(&remainder, mPadded)
                }
            }
        }
        return Data(remainder.drop { $0 == 0 })
    }

    private static func lessThan(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            return x < y
        }
        return false
    }

    private static func subtract(_ a: inout [UInt8], _ b: [UInt8]) {
        var borrow: Int16 = 0
        for index in stride(from: a.count - 1, through: 0, by: -1) {
            var difference = Int16(a[index]) - Int16(b[index]) - borrow
            borrow = difference < 0 ? 1 : 0
            if difference < 0 {
                difference += 256
            }
            a[index] = UInt8(difference)
        }
    }
}
