import Foundation
import Compression

/// Reads files out of a ZIP archive (an EPUB is one) without unpacking it to disk. Stored and deflated entries.
/// A damaged or hostile file must never crash the app: every offset and size is checked against the file first.
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

    /// The biggest single file taken out of a book (a picture or a section is far smaller); a lie in the
    /// directory about a size cannot make the app ask for gigabytes.
    static let maxEntry = 64 * 1024 * 1024
    /// Books bigger than this are read through a memory map, smaller ones into memory (a map breaks if the file
    /// is replaced or evicted while the app holds it, and books are read from where they are, not copied).
    private static let mapAbove = 48 * 1024 * 1024

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    /// the same entries by lowercase name, made once (looking up every miss by hand was slow)
    private var lower: [String: Entry] = [:]

    init(url: URL) throws {
        let size = ZipFile.signature(url).size
        data = try Data(contentsOf: url, options: size > ZipFile.mapAbove ? .mappedIfSafe : [])
        try readDirectory()
    }

    /// The file's size and modification date, to see whether it changed since it was opened.
    static func signature(_ url: URL) -> (date: Date?, size: Int) {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (v?.contentModificationDate, v?.fileSize ?? 0)
    }

    /// true when `len` bytes from `o` lie inside the file
    private func has(_ o: Int, _ len: Int) -> Bool { o >= 0 && len >= 0 && o <= data.count - len }

    private func u16(_ o: Int) -> Int {
        guard has(o, 2) else { return 0 }
        return Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8
    }
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
            guard has(p, 46), u32(p) == 0x0201_4B50 else { break }
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard has(p + 46, nameLen) else { throw Failure(errorDescription: "الملف تالف") }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            let e = Entry(name: name, method: method, compressedSize: csize, size: size, localOffset: local)
            entries[name] = e
            lower[name.lowercased()] = e
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    /// A file's bytes; `name` is its path inside the archive (percent-escapes and "./" are tolerated).
    func read(_ name: String) throws -> Data {
        let clean = name.removingPercentEncoding ?? name
        guard let e = entries[clean] ?? entries[name] ?? lower[clean.lowercased()] else {
            throw Failure(errorDescription: "ما لقيت \(clean) داخل الملف")
        }
        let o = e.localOffset
        guard has(o, 30), u32(o) == 0x0403_4B50 else { throw Failure(errorDescription: "الملف تالف") }
        let start = o + 30 + u16(o + 26) + u16(o + 28)
        guard e.compressedSize <= ZipFile.maxEntry, e.size <= ZipFile.maxEntry, has(start, e.compressedSize) else {
            throw Failure(errorDescription: "الملف تالف")
        }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        if e.method == 0 {
            guard e.size == e.compressedSize else { throw Failure(errorDescription: "الملف تالف") }
            return raw
        }
        guard e.method == 8 else { throw Failure(errorDescription: "طريقة ضغط غير مدعومة") }
        // deflate cannot shrink by more than about 1000 times; a bigger claim is a lie meant to eat memory
        guard e.size <= e.compressedSize * 1000 else { throw Failure(errorDescription: "الملف تالف") }
        if e.size == 0 { return Data() }
        guard e.compressedSize > 0 else { throw Failure(errorDescription: "الملف تالف") }
        var out = Data(count: e.size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            raw.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(d, e.size, s, e.compressedSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == e.size else { throw Failure(errorDescription: "ما قدرت أفك ضغط \(clean)") }
        return out
    }
}
