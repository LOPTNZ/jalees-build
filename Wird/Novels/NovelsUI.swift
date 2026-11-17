import UIKit

/// Screens for pictures and checks on the simulator. Launch with `-JaleesRoute <route>`:
/// `tab-<tab>` (a tab: library, notebook, progress, settings, browse, updates, downloads, history), `notebook-home`,
/// `notebook-marks`, `notebook-book|chars|words|time` (دفتري and the sample novel's notebook page), `site-<id>` (a
/// site's list in تصفّح), `page` (the
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
            // readeren, readeren-guide, readeren-paged…: the reader on an English book (the sample's English text)
            Sample.english = route.hasPrefix("readeren")
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
            } else if route.hasPrefix("notebook") {
                // دفتري (2.4): notebook-home, notebook-marks (every book's highlights), and the sample novel's own notebook
                // (a few things kept from it first): notebook-book, notebook-chars, notebook-words, notebook-time
                fillNotebook(sample, book: book)
                switch route {
                case "notebook-marks": Router.shared.openNotebook(book: nil, kind: "marks")
                case "notebook-book": Router.shared.openNotebook(book: book, kind: nil)
                case "notebook-chars": Router.shared.openNotebook(book: book, kind: "char")
                case "notebook-words": Router.shared.openNotebook(book: book, kind: "word")
                case "notebook-time": Router.shared.openNotebook(book: book, kind: "time")
                default: Router.shared.openNotebook(book: nil, kind: "home")
                }
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
            } else if route == "card" || route == "pdf" || route == "quotecard" {
                // بطاقة الكتاب, ملخص PDF, بطاقة الاقتباس: on the first book that has quotes
                let st = Library.shared.state
                if let b = st.books.first(where: { !$0.items(.quote).isEmpty }) ?? st.books.first {
                    if route == "card" { Flows.bookCard(b.id) } else if route == "pdf" { Flows.pdf(b.id) }
                    else if let q = b.items(.quote).first { Flows.quoteCard(b.id, quote: q.id) }
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
            } else if route.hasPrefix("site-") {
                // a site's list in تصفّح (site-wtrlab), as a tap on its card opens it
                Router.shared.select(.browse)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                NotificationCenter.default.post(name: .browseSite, object: String(route.dropFirst(5)))
            } else if route == "page" {
                Router.shared.select(.browse)
                NovelBridge.showPage(novel: sample.id, book: book, openIndex: nil)
            } else if route.hasPrefix("reader") {
                NovelBridge.openReader(novel: sample.id, book: book, index: 2, chapter: nil, paragraph: nil)
                let parts = route.split(separator: "-")
                if parts.count > 1, let h = NovelBridge.host {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    // a cold start (an iPad turned sideways) can take longer to bring the reader up: wait for it
                    var waited = 0
                    while !(NovelBridge.top(h) is ReaderViewController) && waited < 20 {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        waited += 1
                    }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    (NovelBridge.top(h) as? ReaderViewController)?.debug(String(parts[1]))
                }
            }
        }
    }

    /// A few things kept from the sample novel, for the notebook's pictures: highlights in his named colours (one with
    /// a note), quotes and a word taken from the text (each linked to its highlight), a thought, characters with their
    /// first appearance and relations. Once: the sample's book keeps them.
    static func fillNotebook(_ n: Novel, book: String) {
        guard let b = Library.shared.state.book(book), b.marks.isEmpty, b.chars.isEmpty else { return }
        let chs = Array(Novels.shared.chapters(n.id).prefix(6))
        guard chs.count >= 4 else { return }
        let now = Millis.now
        func para(_ c: ChapterRow, _ i: Int) -> String {
            let t = Sample.text(c).paras
            return t.isEmpty ? "" : t[i % t.count]
        }
        func mark(_ c: ChapterRow, _ i: Int, _ color: String, note: String = "", style: String = "hl", len: Int = 90, ago: Double) -> JSONObject {
            let text = String(para(c, i).prefix(len))
            return ["id": .string(uid()), "color": .string(color), "style": .string(style), "ch": .number(Double(c.id)), "chLabel": .string(c.line),
                    "p": .number(Double(i)), "s": .number(0), "pe": .number(Double(i)), "e": .number(Double(text.count)), "text": .string(text),
                    "note": .string(note), "at": .number(now - ago * DAY)]
        }
        func nv(_ c: ChapterRow, _ i: Int) -> JSONValue {
            .object(["ch": .number(Double(c.id)), "p": .number(Double(i)), "s": .number(0), "label": .string(c.line)])
        }
        var marks: [JSONObject] = [
            mark(chs[0], 0, "purple", note: "المكتبة نفسها شخصية في الرواية؟", ago: 9),
            mark(chs[0], 5, "blue", ago: 9),
            mark(chs[1], 1, "pink", ago: 6),
            mark(chs[2], 4, "yellow", note: "المفتاح الصغير: أكيد له دور بعدين.", ago: 3),
            mark(chs[3], 2, "green", ago: 1)
        ]
        var quotes: [JSONObject] = []
        for (c, i, color, fav, ago) in [(chs[0], 1, "yellow", true, 8.0), (chs[2], 3, "orange", false, 2.0)] {
            var m = mark(c, i, color, len: 120, ago: ago)
            let qid = uid()
            m.set("kind", "quote")
            m.set("item", qid)
            marks.append(m)
            quotes.append(["id": .string(qid), "at": m["at"] ?? .number(now), "text": m["text"] ?? .string(""), "loc": .number(Double(Int(c.num) ?? 1)),
                           "vol": .number(0), "read": .number(1), "speakerId": .string(""), "speakerName": .string(""), "fav": .bool(fav),
                           "nv": nv(c, i), "mark": m["id"] ?? .string(""), "tags": .array([.string("أجواء")])])
        }
        var w = mark(chs[1], 3, "blue", style: "ul", len: 7, ago: 5)
        let wid = uid()
        w.set("kind", "word")
        w.set("item", wid)
        w.set("text", "الفانوس")
        marks.append(w)
        let words: [JSONObject] = [
            ["id": .string(wid), "at": w["at"] ?? .number(now), "word": .string("الفانوس"), "lang": .string("ar"), "tr": .string("lantern"),
             "meaning": .string("مصباح تحيط به جدران من زجاج"), "ex": .string(String(para(chs[0], 0).prefix(80))), "loc": .number(2), "vol": .number(0),
             "nv": nv(chs[1], 3), "mark": w["id"] ?? .string(""), "srs": .null],
            ["id": .string(uid()), "at": .number(now - 4 * DAY), "word": .string("المواسم"), "lang": .string("ar"), "tr": .string(""),
             "meaning": .string("الأوقات التي تتكرر كل عام"), "ex": .string(""), "loc": .number(1), "vol": .number(0),
             "srs": .object(["ease": .number(2.5), "ivl": .number(3), "reps": .number(2), "due": .number(now + 2 * DAY)])]
        ]
        let thoughts: [JSONObject] = [
            ["id": .string(uid()), "at": .number(now - 2 * DAY), "text": .string("كل باب في هذه المكتبة يسأل سؤال قبل ما ينفتح."),
             "passage": .string(String(para(chs[2], 5).prefix(100))), "loc": .number(3), "vol": .number(0), "read": .number(1), "nv": nv(chs[2], 5)]
        ]
        let ids = (0..<4).map { _ in uid() }
        func person(_ i: Int, _ name: String, _ alias: String, _ role: String, _ first: Int, _ rel: [(Int, String)], _ desc: String) -> JSONObject {
            ["id": .string(ids[i]), "at": .number(now - Double(8 - i) * DAY), "name": .string(name), "alias": .string(alias), "role": .string(role),
             "gender": .string(""), "age": .string(""), "desc": .string(desc), "importance": .string(""), "death": .string(""), "appearance": .string(""),
             "traits": .string(""), "flaws": .string(""), "change": .string(""), "challenges": .string(""), "photo": .null, "first": .number(Double(first)),
             "firstVol": .number(0), "rel": .array(rel.map { JSONValue.object(["to": .string(ids[$0.0]), "label": .string($0.1)]) }), "custom": .array([])]
        }
        let chars: [JSONObject] = [
            person(0, "سالم", "الضيف", "main", 1, [(1, "تلميذه"), (2, "صديقته")], "يدخل المكتبة كل ليلة بحثًا عن كتاب وُعد به."),
            person(1, "العجوز", "حارس المكتبة", "main", 1, [(0, "معلّمه"), (3, "خصمه")], "لا يرفع عينه عن دفتره."),
            person(2, "ليلى", "", "secondary", 3, [(0, "صديقها")], "تعرف طريق الرف السابع."),
            person(3, "صاحب الفانوس", "", "secondary", 4, [(1, "خصمه")], "علّق الفانوس النحاسي فوق المدخل.")
        ]
        Library.shared.changeBook(book) { bb in
            bb.marks = marks
            bb.raw.set("quotes", objects: bb.raw.objs("quotes") + quotes)
            bb.raw.set("words", objects: bb.raw.objs("words") + words)
            bb.raw.set("thoughts", objects: bb.raw.objs("thoughts") + thoughts)
            bb.raw.set("chars", objects: chars)
            let bm: JSONObject = ["id": .string(uid()), "ch": .number(Double(chs[2].id)), "chLabel": .string(chs[2].line), "p": .number(6), "o": .number(0), "at": .number(now - DAY)]
            bb.bmarks = [bm]
        }
    }

    /// Makes (or finds) the library book for a novel, the same way adding one does.
    static func ensureBook(_ n: Novel) -> String {
        if !n.book.isEmpty, Library.shared.state.book(n.book) != nil { return n.book }
        return NovelLibrary.ensureBook(["id": n.id, "title": n.title, "author": n.author, "url": n.url, "site": n.source,
                                        "total": n.total, "complete": n.complete, "translator": n.translator, "genres": n.genres])
    }
}
