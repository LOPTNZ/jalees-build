import Foundation
import Compression

/// Reads files out of a ZIP archive (an EPUB is one) without unpacking it to disk. Stored and deflated entries.
final class ZipFile {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localOffset: Int
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        try readDirectory()
    }

    private func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

    private func readDirectory() throws {
        let n = data.count
        guard n > 22 else { throw Failure(errorDescription: "الملف ناقص") }
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65_535)
        while i >= stop {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure(errorDescription: "الملف ما هو ملف EPUB سليم") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4B50 else { break }
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, size: size, localOffset: local)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// A file's bytes; `name` is its path inside the archive (percent-escapes and "./" are tolerated).
    func read(_ name: String) throws -> Data {
        let clean = name.removingPercentEncoding ?? name
        guard let e = entries[clean] ?? entries[name] ?? entries.values.first(where: { $0.name.lowercased() == clean.lowercased() }) else {
            throw Failure(errorDescription: "ما لقيت \(clean) داخل الملف")
        }
        let o = e.localOffset
        guard u32(o) == 0x0403_4B50 else { throw Failure(errorDescription: "الملف تالف") }
        let start = o + 30 + u16(o + 26) + u16(o + 28)
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        if e.method == 0 { return raw }
        guard e.method == 8 else { throw Failure(errorDescription: "طريقة ضغط غير مدعومة") }
        var out = Data(count: max(e.size, 1))
        let written = out.withUnsafeMutableBytes { dst -> Int in
            raw.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, e.compressedSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == e.size else { throw Failure(errorDescription: "ما قدرت أفك ضغط \(clean)") }
        return out
    }
}
