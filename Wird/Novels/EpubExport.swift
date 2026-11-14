import Foundation
import SwiftUI
import UIKit
import Compression

/// تصدير الرواية EPUB لكيندل (answers-round2 س47–س49): the whole novel (or what is saved, or a range) as one EPUB in
/// the same shape and look as Abdullah's Novel Scraper makes them: Thmanyah Serif Text for the text and Serif Display
/// for headings (the OTF files, which Kindle reads), the chapter number large over its title with a thin rule, the
/// word count at the end of each chapter, a cover page, and contents grouped like the site's volumes (or in hundreds).
enum EpubExport {
    struct Options {
        var scope = "all"          // all · saved · range
        var from = 1
        var to = 1
        var groupBy = "volumes"    // volumes · hundreds · none
    }

    /// Builds the file; `progress` gets a short line now and then. Returns its address in the temporary folder.
    @MainActor
    static func build(_ novel: Novel, options o: Options, progress: @escaping (String) -> Void) async throws -> URL {
        let all = Novels.shared.chapters(novel.id)
        var list = all
        switch o.scope {
        case "saved": list = all.filter(\.saved)
        case "range": list = Array(all.dropFirst(max(0, o.from - 1)).prefix(max(0, o.to - o.from + 1)))
        default: break
        }
        guard !list.isEmpty else { throw NovelError.message("ما فيه فصول تنصدّر") }

        // the text of each chapter: saved ones at once, the rest from the site, four at a time
        var texts: [Int: ChapterText] = [:]
        var done = 0
        try await withThrowingTaskGroup(of: (Int, ChapterText?).self) { group in
            var it = list.makeIterator()
            func next() {
                guard let ch = it.next() else { return }
                group.addTask { @MainActor in (ch.id, try? await Novels.shared.text(ch, source: novel.source)) }
            }
            for _ in 0..<4 { next() }
            for try await (id, t) in group {
                if Task.isCancelled { throw CancellationError() }
                texts[id] = t
                done += 1
                if done % 10 == 0 || done == list.count { progress("أجهّز الفصول: \(done) من \(list.count)") }
                next()
            }
        }
        progress("أكتب الملف")

        let name = safeName(novel.title) + ".epub"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let z = try ZipWriter(url)
        try z.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        try z.add("META-INF/container.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8))

        // fonts (only in the app built at home; never in a public place)
        var fonts: [(file: String, family: String, weight: Int)] = []
        for (f, fam, w) in [("thmanyahseriftext-Regular", "body", 400), ("thmanyahseriftext-Bold", "body", 700), ("thmanyahserifdisplay-Bold", "display", 700)] {
            if let u = Bundle.main.url(forResource: f, withExtension: "otf"), let d = try? Data(contentsOf: u) {
                try z.add("OEBPS/style/fonts/\(f).otf", d)
                fonts.append((f + ".otf", fam, w))
            }
        }
        try z.add("OEBPS/style/style.css", Data(stylesheet(fonts).utf8))

        // cover
        var coverFile: String?
        if let img = await cover(novel), let jpg = img.jpegData(compressionQuality: 0.88) {
            try z.add("OEBPS/images/cover.jpg", jpg, compress: false)
            coverFile = "images/cover.jpg"
        }
        try z.add("OEBPS/cover_page.xhtml", Data(coverPage(novel, image: coverFile).utf8))

        // chapters
        var items: [(id: String, file: String, title: String, volume: String)] = []
        for (n, ch) in list.enumerated() {
            guard let t = texts[ch.id] else { continue }
            let file = "chap_\(n + 1).xhtml"
            let paras = Replacer.apply(t.paras, novel: novel.id)
            let title = ch.title.isEmpty ? t.title : ch.title
            try z.add("OEBPS/" + file, Data(chapterPage(number: ch.numbered ? ch.label : nil, title: title.isEmpty ? ch.label : title, paras: paras).utf8))
            items.append(("chap_\(n + 1)", file, ch.numbered ? (title.isEmpty ? ch.label : "\(ch.label) - \(title)") : (title.isEmpty ? ch.label : title), ch.volume))
            if n % 50 == 0 { progress("أكتب الملف: \(n + 1) من \(list.count)") }
        }

        // contents: grouped like the site's volumes, or in hundreds, or flat
        var groups: [(String, [(id: String, file: String, title: String, volume: String)])] = []
        if o.groupBy == "volumes", Set(items.map(\.volume)).count > 1 {
            for it in items {
                if let last = groups.last, last.0 == it.volume { groups[groups.count - 1].1.append(it) } else { groups.append((it.volume, [it])) }
            }
        } else if o.groupBy != "none", items.count > 150 {
            var i = 0
            while i < items.count {
                let chunk = Array(items[i..<min(items.count, i + 100)])
                groups.append(("\(chunk.first!.title)  -  \(chunk.last!.title)", chunk))
                i += 100
            }
        }
        try z.add("OEBPS/nav.xhtml", Data(nav(novel, items: items, groups: groups).utf8))
        try z.add("OEBPS/toc.ncx", Data(ncx(novel, items: items, groups: groups).utf8))
        try z.add("OEBPS/content.opf", Data(opf(novel, items: items, fonts: fonts, cover: coverFile).utf8))
        try z.finish()
        return url
    }

    // MARK: pieces of the book (as the tool writes them)

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func safeName(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"[<>:"/\\|?*]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return t.isEmpty ? "Novel" : t
    }

    private static func page(_ title: String, _ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html dir="rtl" lang="ar" xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>\(esc(title))</title><link rel="stylesheet" href="style/style.css" type="text/css"/></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func chapterPage(number: String?, title: String, paras: [String]) -> String {
        var h = ""
        if let n = number { h += "<h2 class=\"chapter-number\">\(esc(n))</h2>\n<p class=\"chapter-title\">\(esc(title))</p>\n" }
        else { h += "<h2 class=\"chapter-number\">\(esc(title))</h2>\n" }
        h += "<hr class=\"chapter-divider\"/>\n"
        var words = 0
        for p in paras {
            if p.hasPrefix("\u{FFFC}img:") { continue }
            let t = p.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            words += t.split(whereSeparator: { $0.isWhitespace }).count
            h += "<p>\(esc(t))</p>\n"
        }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        h += "<p class=\"word-count\">عدد الكلمات \u{200F} \(f.string(from: NSNumber(value: words)) ?? "\(words)")</p>"
        return page(number.map { "\($0) - \(title)" } ?? title, h)
    }

    private static func coverPage(_ n: Novel, image: String?) -> String {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = "yyyy-MM-dd"
        var b = "<div class=\"cover-page\">"
        if let i = image { b += "<div class=\"cover-image\"><img src=\"\(i)\" alt=\"\"/></div>" }
        b += "<h1>\(esc(n.title))</h1>"
        if !n.author.isEmpty { b += "<div class=\"author\">\(esc(n.author))</div>" }
        b += "<div class=\"meta\">Compiled on \(d.string(from: Date())) — جَليس</div></div>"
        return page(n.title, b)
    }

    private static func stylesheet(_ fonts: [(file: String, family: String, weight: Int)]) -> String {
        var css = ""
        for f in fonts {
            css += "@font-face {\n    font-family: \"\(f.family == "display" ? "NovelDisplayFont" : "NovelBodyFont")\";\n    src: url(\"fonts/\(f.file)\") format(\"opentype\");\n    font-weight: \(f.weight);\n    font-style: normal;\n}\n"
        }
        css += """
        @page { margin: 5pt; }
        body { direction: rtl; text-align: right; font-family: "Amiri", "Traditional Arabic", "Arial", serif; line-height: 1.8; padding: 3%; background-color: #fdfaf3; color: #111111; word-wrap: break-word; overflow-wrap: break-word; word-break: break-word; }
        h1, h2 { text-align: center; color: #6b3e26; margin-bottom: 1.5em; font-weight: bold; }
        .chapter-number { text-align: center; color: #6b3e26; font-size: 1.9em; font-weight: bold; margin-top: 0; margin-bottom: 0.35em; }
        .chapter-title { text-align: center; font-size: 1em; font-weight: bold; margin-top: 0; margin-bottom: 1em; }
        .chapter-divider { border: 0; border-top: 1px solid #6b3e26; width: 55%; margin: 0 auto 1.8em auto; opacity: 0.45; }
        p { text-align: justify; text-justify: inter-word; margin-bottom: 1.2em; margin-top: 0; word-wrap: break-word; overflow-wrap: break-word; word-break: break-word; }
        .word-count { text-align: center; color: #888888; font-size: 0.85em; margin-top: 2em; }
        .cover-page { text-align: center; padding-top: 12%; }
        .cover-image img { max-width: 70%; max-height: 55vh; height: auto; }
        .cover-page h1 { font-size: 2em; color: #6b3e26; }
        .cover-page .author { font-size: 1.2em; color: #444444; margin-top: 1em; }
        .cover-page .meta { font-size: 0.85em; color: #888888; margin-top: 3em; }
        nav ol { list-style: none; padding-right: 1em; }

        """
        if !fonts.isEmpty {
            let fallback = "\"Amiri\", \"Traditional Arabic\", \"Arial\", serif"
            css += "body, p, .word-count { font-family: \"NovelBodyFont\", \(fallback); }\n"
            let heading = fonts.contains { $0.family == "display" } ? "NovelDisplayFont" : "NovelBodyFont"
            css += "h1, h2, h3, .chapter-number, .chapter-title { font-family: \"\(heading)\", \"NovelBodyFont\", \(fallback); }\n"
        }
        return css
    }

    private typealias Item = (id: String, file: String, title: String, volume: String)

    private static func nav(_ n: Novel, items: [Item], groups: [(String, [Item])]) -> String {
        func li(_ it: Item) -> String { "<li><a href=\"\(it.file)\">\(esc(it.title))</a></li>" }
        var b = "<nav epub:type=\"toc\" id=\"toc\"><h1>المحتويات</h1><ol>"
        if groups.isEmpty { b += items.map(li).joined() } else {
            for (name, its) in groups { b += "<li><a href=\"\(its[0].file)\">\(esc(name.isEmpty ? its[0].title : name))</a><ol>" + its.map(li).joined() + "</ol></li>" }
        }
        b += "</ol></nav>"
        return page("المحتويات", b)
    }

    private static func ncx(_ n: Novel, items: [Item], groups: [(String, [Item])]) -> String {
        var order = 0
        func point(_ it: Item) -> String { order += 1; return "<navPoint id=\"np\(order)\" playOrder=\"\(order)\"><navLabel><text>\(esc(it.title))</text></navLabel><content src=\"\(it.file)\"/></navPoint>" }
        var b = ""
        if groups.isEmpty { b = items.map(point).joined() } else {
            for (name, its) in groups {
                order += 1
                let o = order
                b += "<navPoint id=\"np\(o)\" playOrder=\"\(o)\"><navLabel><text>\(esc(name.isEmpty ? its[0].title : name))</text></navLabel><content src=\"\(its[0].file)\"/>" + its.map(point).joined() + "</navPoint>"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="jalees-\(n.id)"/></head>
        <docTitle><text>\(esc(n.title))</text></docTitle><navMap>\(b)</navMap></ncx>
        """
    }

    private static func opf(_ n: Novel, items: [Item], fonts: [(file: String, family: String, weight: Int)], cover: String?) -> String {
        let d = ISO8601DateFormatter()
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        manifest += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        manifest += "<item id=\"style\" href=\"style/style.css\" media-type=\"text/css\"/>"
        manifest += "<item id=\"cover_page\" href=\"cover_page.xhtml\" media-type=\"application/xhtml+xml\"/>"
        if let c = cover { manifest += "<item id=\"cover\" href=\"\(c)\" media-type=\"image/jpeg\" properties=\"cover-image\"/>" }
        for (i, f) in fonts.enumerated() { manifest += "<item id=\"font_\(i)\" href=\"style/fonts/\(f.file)\" media-type=\"font/otf\"/>" }
        for it in items { manifest += "<item id=\"\(it.id)\" href=\"\(it.file)\" media-type=\"application/xhtml+xml\"/>" }
        let spine = "<itemref idref=\"cover_page\"/><itemref idref=\"nav\"/>" + items.map { "<itemref idref=\"\($0.id)\"/>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" dir="rtl" xml:lang="ar">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">jalees-\(n.id)-\(Int(Date().timeIntervalSince1970))</dc:identifier>
        <dc:title>\(esc(n.title))</dc:title><dc:language>ar</dc:language>
        \(n.author.isEmpty ? "" : "<dc:creator>\(esc(n.author))</dc:creator>")
        \(n.summary.isEmpty ? "" : "<dc:description>\(esc(n.summary))</dc:description>")
        <dc:contributor>جَليس</dc:contributor>
        <meta property="dcterms:modified">\(d.string(from: Date()).prefix(19))Z</meta>
        \(cover == nil ? "" : "<meta name=\"cover\" content=\"cover\"/>")
        </metadata>
        <manifest>\(manifest)</manifest>
        <spine toc="ncx" page-progression-direction="rtl">\(spine)</spine>
        </package>
        """
    }

    /// The cover the library shows (yours if you changed it), else the site's.
    @MainActor
    private static func cover(_ n: Novel) async -> UIImage? {
        if !n.book.isEmpty, let img = Library.shared.image(Library.shared.state.book(n.book)?.cover) { return img }
        guard let u = URL(string: n.cover), !n.cover.isEmpty, let (d, _) = try? await URLSession.shared.data(from: u) else { return nil }
        return UIImage(data: d)
    }
}

// MARK: - a small zip writer (deflate through Apple's Compression), enough for EPUB files

final class ZipWriter {
    private let h: FileHandle
    private var central = Data()
    private var count = 0
    private var offset: UInt32 = 0

    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        h = try FileHandle(forWritingTo: url)
    }

    func add(_ path: String, _ data: Data, compress: Bool = true) throws {
        let name = Data(path.utf8)
        let crc = CRC32.of(data)
        var body = data
        var method: UInt16 = 0
        if compress, data.count > 64, let d = Self.deflate(data), d.count < data.count { body = d; method = 8 }
        var local = Data()
        local.le32(0x04034b50); local.le16(20); local.le16(0x0800); local.le16(method); local.le16(0); local.le16(0x21)
        local.le32(crc); local.le32(UInt32(body.count)); local.le32(UInt32(data.count)); local.le16(UInt16(name.count)); local.le16(0)
        local.append(name)
        h.write(local)
        h.write(body)
        var c = Data()
        c.le32(0x02014b50); c.le16(20); c.le16(20); c.le16(0x0800); c.le16(method); c.le16(0); c.le16(0x21)
        c.le32(crc); c.le32(UInt32(body.count)); c.le32(UInt32(data.count)); c.le16(UInt16(name.count)); c.le16(0); c.le16(0)
        c.le16(0); c.le16(0); c.le32(0); c.le32(offset)
        c.append(name)
        central.append(c)
        offset += UInt32(local.count + body.count)
        count += 1
    }

    func finish() throws {
        h.write(central)
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(offset); end.le16(0)
        h.write(end)
        try h.close()
    }

    /// Raw DEFLATE (what zip wants), from Apple's Compression.
    private static func deflate(_ data: Data) -> Data? {
        let cap = data.count + 1024
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        out.count = n
        return out
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func of(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
        return c ^ 0xFFFFFFFF
    }
}

/// «تصدير EPUB»: which chapters, how the contents are grouped, then the file goes to the share sheet (Files, Kindle…).
struct EpubExportSheet: View {
    let novel: Novel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.look) private var L
    @State private var o = EpubExport.Options()
    @State private var busy = false
    @State private var status = ""
    @State private var job: Task<Void, Never>?

    var body: some View {
        let all = Novels.shared.chapters(novel.id)
        let saved = all.filter(\.saved).count
        JSheet(title: "تصدير EPUB") {
            Text("ملف EPUB بشكل أداتك: خط ثمانية، رقم الفصل فوق عنوانه، وعدد الكلمات آخر كل فصل. يروح لتطبيق «الملفات» أو كيندل.")
                .font(JFont.body(13.5)).foregroundStyle(Color(L.ink2))
            JLabel(text: "الفصول")
            JSeg(options: [("all", "كلها (\(all.count))"), ("saved", "المحمّل (\(saved))"), ("range", "من إلى")], value: $o.scope)
            if o.scope == "range" {
                HStack(spacing: 10) {
                    Stepper("من \(o.from)", value: $o.from, in: 1...max(1, all.count)).font(JFont.body(15))
                    Stepper("إلى \(o.to)", value: $o.to, in: o.from...max(o.from, all.count)).font(JFont.body(15))
                }
            }
            if o.scope == "all" && saved < all.count {
                Text("الفصول غير المحمّلة (\(all.count - saved)) تنجاب من الموقع أول، وتبقى محفوظة بعدها.").font(JFont.body(12.5)).foregroundStyle(Color(L.ink2))
            }
            JLabel(text: "المحتويات")
            JSeg(options: [("volumes", "مثل المجلدات"), ("hundreds", "كل 100 فصل"), ("none", "قائمة وحدة")], value: $o.groupBy)
            if busy {
                HStack(spacing: 8) { ProgressView(); Text(status).font(JFont.body(14)).foregroundStyle(Color(L.ink2)) }
                Button("إيقاف") { job?.cancel(); busy = false }.buttonStyle(JButtonStyle(look: L, small: true))
            } else {
                Button { start() } label: { Label("إنشاء الملف", systemImage: "book.closed").frame(maxWidth: .infinity) }
                    .buttonStyle(JButtonStyle(look: L, primary: true))
            }
        }
        .onAppear { o.to = max(1, all.count) }
    }

    private func start() {
        busy = true
        status = "أبدأ"
        job = Task { @MainActor in
            do {
                let url = try await EpubExport.build(novel, options: o) { s in status = s }
                busy = false
                Share.files([url])
            } catch is CancellationError {
                busy = false
            } catch {
                busy = false
                ToastCenter.shared.show("تعذّر إنشاء الملف: " + error.localizedDescription)
            }
        }
    }
}
