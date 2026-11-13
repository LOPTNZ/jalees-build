import UIKit

/// Screens for pictures and checks on the simulator. Launch with `-JaleesRoute <route>`:
/// `tab-<tab>` (a tab: library, notebook, progress, settings, browse, updates, downloads, history), `page` (the
/// built-in sample novel's page), `reader` and `reader-<what>` (see ReaderViewController.debug), `epub` / `epub-read`,
/// and `live <series url> <chapter number>` (adds a real novel and opens that chapter).
@MainActor
enum DebugRoute {
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-JaleesRoute"), i + 1 < args.count else { return }
        let route = args[i + 1]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if route == "live", i + 2 < args.count {
                do {
                    let r = try await Novels.shared.add(url: args[i + 2]) { s in NSLog("jalees live: %@", s) }
                    let book = ensureBook(r.novel)
                    let chs = Novels.shared.chapters(r.novel.id)
                    let want = i + 3 < args.count ? args[i + 3] : "1"
                    let at = chs.firstIndex { $0.num == want } ?? 0
                    NovelBridge.openReader(novel: r.novel.id, book: book, index: at, chapter: nil, paragraph: nil)
                } catch {
                    NSLog("jalees live: failed %@", error.localizedDescription)
                }
                return
            }
            if route.hasPrefix("epub") {
                // the simulator check copies tools/sim/sample.epub into the app's Documents folder
                let f = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("sample.epub")
                NovelBridge.importEpub(f)
                if route == "epub-read" {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if let n = Novels.shared.list.first(where: { $0.source == "epub" }) {
                        NovelBridge.openReader(novel: n.id, book: n.book, index: 0, chapter: nil, paragraph: nil)
                    }
                }
                return
            }
            // every check starts from the default way of reading
            if !route.contains("paged") && !route.contains("curl") { ReaderSettings.shared.prefs.mode = route.contains("swipe") ? "continuous" : "chapter" }
            guard let sample = Sample.ensure() else { return }
            let book = ensureBook(sample)
            if route.hasPrefix("tab-") {
                guard let t = Router.Tab(rawValue: String(route.dropFirst(4))) else { return }
                if t == .history { for c in Novels.shared.chapters(sample.id).prefix(3) { Novels.shared.logHistory(novel: sample.id, chapter: c.id) } }
                if t == .updates {
                    let ids = Novels.shared.chapters(sample.id).suffix(3).map(\.id)
                    for (k, id) in ids.enumerated() { DB.shared.run("UPDATE chapters SET found=? WHERE id=?", [Date().timeIntervalSince1970 - Double(k * 90_000), id]) }
                    DB.shared.set("updates.checked", String(Date().timeIntervalSince1970))
                }
                Router.shared.select(t)
            } else if route.hasPrefix("form") {
                // the book form: adding (form), searching online (formsearch), editing (formedit), many (multi)
                if route == "formedit" { Flows.editBook(Library.shared.state.lastBookId() ?? "") } else { Flows.addBook() }
                if route == "formsearch" {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    NotificationCenter.default.post(name: .formQuery, object: "البؤساء")
                }
            } else if route.hasPrefix("session") {
                // a reading session on the book read last (sessionend: its end sheet too)
                let st = Library.shared.state
                if let id = st.books.first(where: { $0.status == .reading && !$0.isNovel })?.id {
                    SessionModel.shared.start(id)
                    if route == "sessionend" { try? await Task.sleep(nanoseconds: 2_500_000_000); SessionModel.shared.beginEnd() }
                }
            } else if route == "finish" {
                if let b = Library.shared.state.books.first(where: { $0.status == .done }) { Flows.finish(b.id, volume: nil) }
            } else if route.hasPrefix("note-") {
                // the notebook's forms and cards: note-quote (a new quote), note-char (a character's card), note-review (words)
                let st = Library.shared.state
                let what = String(route.dropFirst(5))
                if what == "char", let b = st.books.first(where: { !$0.chars.isEmpty }), let c = b.chars.first {
                    Router.shared.select(.notebook)
                    Present.shared.open(.character(b.id, c.id))
                } else if what == "review" {
                    Present.shared.open(.review(nil))
                } else if let b = st.books.first(where: { $0.status == .reading }) {
                    Flows.note(b.id, kind: what)
                }
            } else if route.hasPrefix("settings") {
                // الإعدادات: settings, settings-reset (its confirmation), settings-data (scrolled to the data section)
                Router.shared.select(.settings)
                try? await Task.sleep(nanoseconds: 700_000_000)
                if route == "settings-reset" { NotificationCenter.default.post(name: .settingsDebug, object: "reset") }
            } else if route.hasPrefix("prog") {
                // إنجازاتي: prog-goals, prog-goals:ach, prog-stats, prog-stats:facts
                Router.shared.select(.progress)
                try? await Task.sleep(nanoseconds: 700_000_000)
                NotificationCenter.default.post(name: .progressShow, object: String(route.dropFirst(5)))
            } else if route == "multi" {
                Flows.multiAdd()
            } else if route == "shelfedit" {
                Library.shared.change { $0.settings.view = "shelf" }
                Router.shared.select(.library)
                try? await Task.sleep(nanoseconds: 800_000_000)
                ShelfEditor.shared.begin(width: UIScreen.main.bounds.width)
                if let first = ShelfEditor.shared.draft.first?.first { ShelfEditor.shared.setPose(first.id, "face") }
            } else if route.hasPrefix("lib-") {
                // the library in one of its views: carousel, grid, shelf
                let v = String(route.dropFirst(4))
                Library.shared.change { st in
                    st.settings.view = v == "flow" ? "carousel" : v
                    st.settings.carStyle = v == "flow" ? "flow" : "stack"
                }
                Router.shared.select(.library)
            } else if route.hasPrefix("book") {
                // a book's page: the one read last, or the n-th book (book-3)
                Router.shared.select(.library)
                let st = Library.shared.state
                let n = Int(route.split(separator: "-").last ?? "") ?? -1
                let id = n >= 0 && n < st.books.count ? st.books[n].id : (st.lastBookId() ?? "")
                if let b = st.book(id) { try? await Task.sleep(nanoseconds: 600_000_000); OpenBook.open(b) }
            } else if route == "page" {
                Router.shared.select(.browse)
                NovelBridge.showPage(novel: sample.id, book: book, openIndex: nil)
            } else if route.hasPrefix("reader") {
                NovelBridge.openReader(novel: sample.id, book: book, index: 2, chapter: nil, paragraph: nil)
                let parts = route.split(separator: "-")
                if parts.count > 1, let h = NovelBridge.host {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    (NovelBridge.top(h) as? ReaderViewController)?.debug(String(parts[1]))
                }
            }
        }
    }

    /// Makes (or finds) the library book for a novel, the same way adding one does.
    static func ensureBook(_ n: Novel) -> String {
        if !n.book.isEmpty, Library.shared.state.book(n.book) != nil { return n.book }
        return NovelLibrary.ensureBook(["id": n.id, "title": n.title, "author": n.author, "url": n.url, "site": n.source,
                                        "total": n.total, "complete": n.complete, "translator": n.translator, "genres": n.genres])
    }
}
