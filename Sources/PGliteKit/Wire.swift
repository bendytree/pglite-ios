import Foundation

/// PostgreSQL wire-protocol (v3) encoding/decoding — exactly the subset the
/// embedded single-connection engine needs: simple + extended query flows,
/// text-format parameters and results.
enum Wire {
    // MARK: frontend messages

    static func simpleQuery(_ sql: String) -> Data {
        message("Q") { $0.cstring(sql) }
    }

    /// One-shot extended query: Parse + Bind + Describe + Execute + Sync.
    static func extendedQuery(_ sql: String, params: [PGValue?]) -> Data {
        var out = Data()
        out.append(message("P") {
            $0.cstring("")        // unnamed statement
            $0.cstring(sql)
            $0.int16(0)           // no parameter type hints; server infers
        })
        out.append(message("B") {
            $0.cstring("")        // unnamed portal
            $0.cstring("")        // unnamed statement
            $0.int16(1)           // one param format code…
            $0.int16(0)           // …all text
            $0.int16(Int16(params.count))
            for p in params {
                if let p {
                    let bytes = Data(p.textValue.utf8)
                    $0.int32(Int32(bytes.count))
                    $0.raw(bytes)
                } else {
                    $0.int32(-1)  // NULL
                }
            }
            $0.int16(1)           // one result format code…
            $0.int16(0)           // …all text
        })
        out.append(message("D") {
            $0.uint8(UInt8(ascii: "P"))
            $0.cstring("")
        })
        out.append(message("E") {
            $0.cstring("")
            $0.int32(0)           // no row limit
        })
        out.append(message("S") { _ in })
        return out
    }

    private static func message(_ type: String, _ body: (inout Writer) -> Void) -> Data {
        var w = Writer()
        body(&w)
        var out = Data(capacity: w.data.count + 5)
        out.append(type.utf8.first!)
        var len = UInt32(w.data.count + 4).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(w.data)
        return out
    }

    struct Writer {
        var data = Data()
        mutating func uint8(_ v: UInt8) { data.append(v) }
        mutating func int16(_ v: Int16) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        mutating func int32(_ v: Int32) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        mutating func cstring(_ s: String) {
            data.append(contentsOf: s.utf8)
            data.append(0)
        }
        mutating func raw(_ d: Data) { data.append(d) }
    }

    // MARK: backend messages

    struct BackendMessage {
        let type: UInt8
        let body: Data
    }

    static func frames(_ data: Data) -> [BackendMessage] {
        var out: [BackendMessage] = []
        var off = data.startIndex
        while data.endIndex - off >= 5 {
            let type = data[off]
            let len = Int(UInt32(data[off + 1]) << 24 | UInt32(data[off + 2]) << 16
                | UInt32(data[off + 3]) << 8 | UInt32(data[off + 4]))
            guard len >= 4, off + 1 + len <= data.endIndex else { break }
            out.append(BackendMessage(
                type: type,
                body: data.subdata(in: (off + 5)..<(off + 1 + len))
            ))
            off += 1 + len
        }
        return out
    }

    static func rowDescription(_ body: Data) -> [PGColumn] {
        var r = Reader(body)
        guard let n = r.int16() else { return [] }
        var cols: [PGColumn] = []
        for _ in 0..<n {
            guard let name = r.cstring() else { break }
            _ = r.int32() // table oid
            _ = r.int16() // attnum
            let typeOid = r.int32() ?? 0
            _ = r.int16() // typlen
            _ = r.int32() // typmod
            _ = r.int16() // format
            cols.append(PGColumn(name: name, typeOid: UInt32(bitPattern: typeOid)))
        }
        return cols
    }

    static func dataRow(_ body: Data) -> [Data?] {
        var r = Reader(body)
        guard let n = r.int16() else { return [] }
        var vals: [Data?] = []
        for _ in 0..<n {
            guard let len = r.int32() else { break }
            if len < 0 {
                vals.append(nil)
            } else {
                vals.append(r.bytes(Int(len)))
            }
        }
        return vals
    }

    /// ErrorResponse / NoticeResponse: repeated <field-byte><cstring>, NUL end.
    static func errorFields(_ body: Data) -> [Character: String] {
        var out: [Character: String] = [:]
        var r = Reader(body)
        while let k = r.uint8(), k != 0 {
            guard let v = r.cstring() else { break }
            out[Character(UnicodeScalar(k))] = v
        }
        return out
    }

    struct Reader {
        let data: Data
        var off: Data.Index
        init(_ d: Data) {
            data = d
            off = d.startIndex
        }
        mutating func uint8() -> UInt8? {
            guard off < data.endIndex else { return nil }
            defer { off += 1 }
            return data[off]
        }
        mutating func int16() -> Int16? {
            guard data.endIndex - off >= 2 else { return nil }
            defer { off += 2 }
            return Int16(bitPattern: UInt16(data[off]) << 8 | UInt16(data[off + 1]))
        }
        mutating func int32() -> Int32? {
            guard data.endIndex - off >= 4 else { return nil }
            defer { off += 4 }
            return Int32(bitPattern: UInt32(data[off]) << 24 | UInt32(data[off + 1]) << 16
                | UInt32(data[off + 2]) << 8 | UInt32(data[off + 3]))
        }
        mutating func cstring() -> String? {
            guard let nul = data[off...].firstIndex(of: 0) else { return nil }
            defer { off = nul + 1 }
            return String(data: data[off..<nul], encoding: .utf8)
        }
        mutating func bytes(_ n: Int) -> Data? {
            guard data.endIndex - off >= n else { return nil }
            defer { off += n }
            return data.subdata(in: off..<(off + n))
        }
    }
}
