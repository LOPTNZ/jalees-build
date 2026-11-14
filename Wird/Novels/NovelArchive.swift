import UIKit
import UniformTypeIdentifiers

/// استيراد أرشيف أداتك (answers-round2 س20، س67): a novel folder made by Novel Scraper (config.json, cache/chapter_NNNN.json,
/// cover image), copied to the Files app, becomes a novel in Jalees with every chapter already saved. It reads like any
/// novel, offline. Its site address is kept, so it can be moved to the live site later.
@MainActor
enum NovelArchive {
    private static var picker: Picker?

    static func pick() {
        guard let h = NovelBridge.host else { return }
        let p = Picker()
        picker = p
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        vc.delegate = p
        vc.allowsMultipleSelection = false
        NovelBridge.top(h).present(vc, animated: true)
    }

    private final class Picker: NSObject, UIDocumentPickerDelegate {
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let u = urls.first else { return }
            Task { @MainActor in NovelArchive.importFolder(u); NovelArchive.picker = nil }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in NovelArchive.picker = nil }
        }
    }

    static func importFolder(_ folder: URL) {
        let ok = folder.startAccessingSecurityScopedResource()
        Toaster.show("أقرأ الأرشيف…")
        Task.detached(priority: .userInitiated) {
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            let r = read(folder)
            await MainActor.run { save(r, folder: folder) }
        }
    }

    struct Read {
        var title = "", author = "", summary = "", series = ""
        var chapters: [(n: Int, num: String, title: String, url: String, paras: [String])] = []
        var cover: Data?
        var error: String?
    }

    /// Reads the folder off the main thread: the settings, every cached chapter in order, and the cover.
    nonisolated static func read(_ folder: URL) -> Read {
        var r = Read()
        let fm = FileManager.default
        if let d = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
           let c = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            r.title = (c["novel_title"] as? String) ?? ""
            r.author = (c["novel_author"] as? String) ?? ""
            r.summary = (c["novel_description"] as? String) ?? ""
            r.series = (c["series_url"] as? String) ?? (c["start_url"] as? String) ?? ""
        }
        if r.title.isEmpty { r.title = folder.lastPathComponent }
        let cache = folder.appendingPathComponent("cache")
        let files = ((try? fm.contentsOfDirectory(atPath: cache.path)) ?? []).filter { $0.hasPrefix("chapter_") && $0.hasSuffix(".json") }.sorted()
        guard !files.isEmpty else { r.error = "ما لقيت فصول في هالمجلد (مجلد cache فيه ملفات chapter_….json)"; return r }
        for f in files {
            guard let d = try? Data(contentsOf: cache.appendingPathComponent(f)), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            var paras: [String] = []
            if let p = o["paragraphs"] as? [String] { paras = p }
            else if let blocks = o["blocks"] as? [[String: Any]] { paras = blocks.compactMap { ($0["type"] as? String) == "image" ? nil : $0["text"] as? String } }
            paras = paras.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !paras.isEmpty else { continue }
            let n = Int(f.dropFirst(8).prefix { $0.isNumber }) ?? (r.chapters.count + 1)
            var title = (o["title"] as? String) ?? ""
            var num = ((o["number"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            // «01: قرمزي.» → number 1, title «قرمزي.»
            if let m = title.range(of: #"^\s*[\d٠-٩]+\s*[:：.\-–—]\s*"#, options: .regularExpression) {
                if num.isEmpty { num = String(title[m].filter { $0.isNumber }) }
                title.removeSubrange(m)
            }
            if num.isEmpty { num = String(n) }
            // the first line is often the heading again: drop it when it repeats the title
            if let first = paras.first, first.contains(title), !title.isEmpty, first.count < title.count + 12 { paras.removeFirst() }
            r.chapters.append((n, num, title.trimmingCharacters(in: .whitespaces), (o["url"] as? String) ?? "", paras))
        }
        for name in ["cover.png", "cover.jpg", "cover.jpeg", "cover.webp"] {
            if let d = try? Data(contentsOf: folder.appendingPathComponent(name)) { r.cover = d; break }
        }
        if r.chapters.isEmpty { r.error = "الملفات موجودة بس ما فيها نص" }
        return r
    }

    private static func save(_ r: Read, folder: URL) {
        if let e = r.error { Toaster.show(e); return }
        let db = DB.shared
        let key = "archive://" + (r.series.isEmpty ? r.title : r.series)
        if let old = db.query("SELECT id FROM novels WHERE url=?", [key]).first {
            Toaster.show("«\(r.title)» مستورد من قبل")
            Router.shared.openNovel(old.int("id"), book: Novels.shared.list.first { $0.id == old.int("id") }?.book ?? "")
            return
        }
        var nid = 0
        let now = Date().timeIntervalSince1970
        db.transaction {
            nid = Int(db.run("INSERT INTO novels(source,url,title,author,cover,summary,status,total,added,updated) VALUES('archive',?,?,?,?,?,?,?,?,?)",
                             [key, r.title, r.author, "", r.summary, "", r.chapters.count, now, now]))
            for (i, c) in r.chapters.enumerated() {
                let cid = Int(db.run("INSERT INTO chapters(novel,idx,num,title,url) VALUES(?,?,?,?,?)",
                                     [nid, i, c.num, c.title, c.url.isEmpty ? "\(key)#\(c.n)" : c.url + "#archive"]))
                let json = String(data: (try? JSONSerialization.data(withJSONObject: c.paras)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
                let words = c.paras.reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count }
                db.run("INSERT INTO texts(chapter,title,paras,removed,fetched) VALUES(?,?,?,?,?)", [cid, c.title, json, 0, now])
                db.run("UPDATE chapters SET words=? WHERE id=?", [words, cid])
            }
        }
        Novels.shared.reload()
        let book = NovelLibrary.ensureBook(["id": nid, "title": r.title, "author": r.author, "url": r.series, "site": "archive",
                                            "total": r.chapters.count, "complete": true, "genres": [String]()])
        if let d = r.cover, let img = UIImage(data: d) { NovelLibrary.setCover(book, img) }
        Router.shared.openNovel(nid, book: book)
        Toaster.show("انضافت «\(r.title)»: \(r.chapters.count) فصل محفوظ")
    }
}
