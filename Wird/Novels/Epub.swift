import UIKit
import UniformTypeIdentifiers

/// EPUB books read from where they are (Files, iCloud on the phone, the «جليس» folder): the app keeps only a
/// bookmark to the file, never a second copy. Each book becomes a "novel" with source «epub», so the same reader,
/// highlights, notebook and sessions work for it; its sections are the chapters.
enum EpubStore {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Open archives, kept while the app runs (reading a section or a picture needs no reopening).
    private static var open: [String: ZipFile] = [:]
    private static let lock = NSLock()

    /// A path inside the book, from a folder and a link (handles "../" and percent escapes).
    static func normPath(_ base: String, _ href: String) -> String {
        let h = (href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href
        let joined = base.isEmpty ? h : (base as NSString).appendingPathComponent(h)
        return (joined as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: the file, kept where it is

    private static func key(_ id: String) -> String { "epub." + id }

    static func fileURL(_ id: String) throws -> URL {
        guard let s = DB.shared.get(key(id)), let d = Data(base64Encoded: s) else { throw Failure(errorDescription: "ما لقيت مكان الملف") }
        var stale = false
        let u = try URL(resolvingBookmarkData: d, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale, let fresh = try? u.bookmarkData() { DB.shared.set(key(id), fresh.base64EncodedString()) }
        return u
    }

    static func zip(_ id: String) throws -> ZipFile {
        lock.lock(); defer { lock.unlock() }
        if let z = open[id] { return z }
        let u = try fileURL(id)
        let scoped = u.startAccessingSecurityScopedResource()
        defer { if scoped { u.stopAccessingSecurityScopedResource() } }
        let z = try ZipFile(url: u)
        open[id] = z
        return z
    }

    static func id(of novel: Novel) -> String {
        novel.url.hasPrefix("epub:") ? String(novel.url.dropFirst(5)) : novel.url
    }

    // MARK: adding a book

    struct Added {
        let novel: Novel
        let cover: Data?
    }

    /// Reads the book's table of contents and makes it a novel whose chapters are the book's sections.
    @MainActor
    static func add(_ url: URL) throws -> Added {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let mark = try url.bookmarkData()
        let z = try ZipFile(url: url)
        let opfPath = try rootFile(z)
        let opf = try OPF(data: z.read(opfPath))
        let base = (opfPath as NSString).deletingLastPathComponent
        func full(_ href: String) -> String { normPath(base, href) }
        var titles: [String: String] = [:]
        if let nav = opf.navHref, let d = try? z.read(full(nav)) { titles = TOC.fromNav(d, base: (full(nav) as NSString).deletingLastPathComponent) }
        if titles.isEmpty, let ncx = opf.ncxHref, let d = try? z.read(full(ncx)) { titles = TOC.fromNCX(d, base: (full(ncx) as NSString).deletingLastPathComponent) }

        let id = UUID().uuidString
        DB.shared.set(key(id), mark.base64EncodedString())
        lock.lock(); open[id] = z; lock.unlock()
        let db = DB.shared
        var novelID = 0
        var n = 0
        db.transaction {
            novelID = Int(db.run("INSERT INTO novels(source,url,title,author,summary,status,total,added,updated) VALUES('epub',?,?,?,?,?,?,?,?)",
                                 ["epub:" + id, opf.title.isEmpty ? url.deletingPathExtension().lastPathComponent : opf.title, opf.author,
                                  opf.summary, "مكتملة", opf.spine.count, Date().timeIntervalSince1970, Date().timeIntervalSince1970]))
            for href in opf.spine {
                let path = full(href)
                let t = titles[path] ?? ""
                db.run("INSERT OR IGNORE INTO chapters(novel,idx,num,title,url) VALUES(?,?,?,?,?)", [novelID, n, "", t.isEmpty ? "القسم \(n + 1)" : t, "epub:" + id + "/" + path])
                n += 1
            }
        }
        Novels.shared.reload()
        guard let novel = Novels.shared.novel(novelID) else { throw Failure(errorDescription: "ما انحفظ الكتاب") }
        let cover = opf.coverHref.flatMap { try? z.read(full($0)) }
        return Added(novel: novel, cover: cover)
    }

    private static func rootFile(_ z: ZipFile) throws -> String {
        let d = try z.read("META-INF/container.xml")
        let s = String(decoding: d, as: UTF8.self)
        guard let r = s.range(of: #"full-path\s*=\s*"([^"]+)""#, options: .regularExpression) else { throw Failure(errorDescription: "الملف ما هو EPUB") }
        return String(s[r]).components(separatedBy: "\"")[1]
    }

    // MARK: reading

    /// A section's words without its markup, for looking up a name.
    static func rawText(url: String) throws -> String {
        let rest = url.dropFirst(5)
        guard let slash = rest.firstIndex(of: "/") else { return "" }
        let id = String(rest[..<slash]), path = String(rest[rest.index(after: slash)...])
        let html = String(decoding: try zip(id).read(path), as: UTF8.self)
        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    /// A section as paragraphs (pictures become their own paragraphs, drawn by the reader).
    @MainActor
    static func text(_ ch: ChapterRow) async throws -> ChapterText {
        let rest = ch.url.dropFirst(5)
        guard let slash = rest.firstIndex(of: "/") else { throw Failure(errorDescription: "عنوان قسم غير صالح") }
        let id = String(rest[..<slash]), path = String(rest[rest.index(after: slash)...])
        let z = try zip(id)
        let html = String(decoding: try z.read(path), as: UTF8.self)
        let url = "wirdapp://app/epub/" + id + "/" + path
        guard let d = try await SourceEngine.shared.run("epub", "chapter", html: html, url: url) as? [String: Any] else { throw NovelError.parse("epub") }
        let paras = (d["paras"] as? [String]) ?? []
        return ChapterText(title: (d["title"] as? String) ?? "", paras: paras.isEmpty ? [" "] : paras, removed: 0)
    }

    /// A picture or other file from inside a book, for the reader page (wirdapp://app/epub/<id>/<path>).
    static func resource(_ id: String, _ path: String) -> Data? {
        guard let z = try? zip(id) else { return nil }
        return try? z.read(path)
    }

    // MARK: choosing a file

    private static var picker: PickerDelegate?

    @MainActor
    static func pick(from vc: UIViewController, done: @escaping (URL?) -> Void) {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "epub") ?? .data], asCopy: false)
        let d = PickerDelegate(done: done)
        picker = d
        p.delegate = d
        p.allowsMultipleSelection = false
        vc.present(p, animated: true)
    }

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
    }
}

/// The package file: title, author, cover, reading order, and where the table of contents is.
private final class OPF: NSObject, XMLParserDelegate {
    var title = ""
    var author = ""
    var summary = ""
    var spine: [String] = []
    var navHref: String?
    var ncxHref: String?
    var coverHref: String?
    private var manifest: [String: (href: String, type: String, props: String)] = [:]
    private var spineIDs: [String] = []
    private var coverID: String?
    private var tocID: String?
    private var current = ""
    private var buffer = ""

    init(data: Data) throws {
        super.init()
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldProcessNamespaces = false
        guard p.parse() || !manifest.isEmpty else { throw EpubStore.Failure(errorDescription: "ما قدرت أقرأ فهرس الكتاب") }
        spine = spineIDs.compactMap { manifest[$0]?.href }
        if let t = tocID { ncxHref = manifest[t]?.href }
        if ncxHref == nil { ncxHref = manifest.values.first { $0.type == "application/x-dtbncx+xml" }?.href }
        navHref = manifest.values.first { $0.props.contains("nav") }?.href
        coverHref = manifest.values.first { $0.props.contains("cover-image") }?.href ?? coverID.flatMap { manifest[$0]?.href }
    }

    private func local(_ n: String) -> String { n.components(separatedBy: ":").last ?? n }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        let n = local(name)
        current = n
        buffer = ""
        switch n {
        case "item":
            if let id = a["id"], let href = a["href"] { manifest[id] = (href.removingPercentEncoding ?? href, a["media-type"] ?? "", a["properties"] ?? "") }
        case "itemref":
            if let id = a["idref"], a["linear"] != "no" { spineIDs.append(id) }
        case "spine":
            tocID = a["toc"]
        case "meta":
            if a["name"] == "cover" { coverID = a["content"] }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(name) {
        case "title": if title.isEmpty { title = t }
        case "creator": if author.isEmpty { author = t }
        case "description": if summary.isEmpty { summary = t.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }
        default: break
        }
        buffer = ""
    }
}

/// Section titles from the book's own table of contents (EPUB 3 nav or EPUB 2 NCX), by section path.
private enum TOC {
    static func fromNav(_ d: Data, base: String) -> [String: String] {
        let s = String(decoding: d, as: UTF8.self)
        var out: [String: String] = [:]
        let re = try? NSRegularExpression(pattern: ##"<a[^>]*href\s*=\s*"([^"#]+)[^"]*"[^>]*>(.*?)</a>"##, options: [.dotMatchesLineSeparators, .caseInsensitive])
        for m in re?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? [] {
            guard let h = Range(m.range(at: 1), in: s), let t = Range(m.range(at: 2), in: s) else { continue }
            let path = join(base, String(s[h]))
            let title = String(s[t]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if out[path] == nil, !title.isEmpty { out[path] = title }
        }
        return out
    }

    static func fromNCX(_ d: Data, base: String) -> [String: String] {
        let s = String(decoding: d, as: UTF8.self)
        var out: [String: String] = [:]
        let re = try? NSRegularExpression(pattern: ##"<navLabel>\s*<text>(.*?)</text>\s*</navLabel>\s*<content[^>]*src\s*=\s*"([^"#]+)"##, options: [.dotMatchesLineSeparators, .caseInsensitive])
        for m in re?.matches(in: s, range: NSRange(s.startIndex..., in: s)) ?? [] {
            guard let t = Range(m.range(at: 1), in: s), let h = Range(m.range(at: 2), in: s) else { continue }
            let path = join(base, String(s[h]))
            let title = String(s[t]).trimmingCharacters(in: .whitespacesAndNewlines)
            if out[path] == nil, !title.isEmpty { out[path] = title }
        }
        return out
    }

    private static func join(_ base: String, _ href: String) -> String { EpubStore.normPath(base, href) }
}
