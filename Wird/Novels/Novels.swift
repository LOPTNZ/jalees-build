import UIKit
import WebKit

// MARK: - data

struct Novel: Identifiable, Equatable {
    let id: Int
    var source: String
    var url: String
    var title: String
    var author: String
    var cover: String
    var summary: String
    var status: String
    var total: Int
    var curChapter: Int
    var curP: Int
    var curO: Double
    var book: String
    var translator: String
    var genres: [String]

    /// «مكتملة» on the site means no new chapters will come.
    var complete: Bool { status.contains("مكتمل") }
    var siteName: String { Self.siteNames[source] ?? (source == "generic" ? (URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "موقع آخر") : source) }
    static let siteNames = ["kolnovel": "ملوك الروايات", "cenele": "فضاء الروايات", "rewayat": "نادي الروايات", "realmnovel": "realmnovel",
                            "layl": "Layl", "wetriedtls": "We Tried TLs", "wtrlab": "WTR-LAB", "ranobes": "Ranobes",
                            "archive": "أرشيف أداتك", "epub": "ملف EPUB", "sample": "جليس"]

    init(row: [String: Any]) {
        id = row.int("id"); source = row.str("source"); url = row.str("url"); title = row.str("title")
        author = row.str("author"); cover = row.str("cover"); summary = row.str("summary"); status = row.str("status")
        total = row.int("total"); curChapter = row.int("cur_chapter"); curP = row.int("cur_p"); curO = row.dbl("cur_o")
        book = row.str("book"); translator = row.str("translator")
        genres = row.str("genres").split(separator: "|").map(String.init).filter { !$0.isEmpty }
    }
}

struct ChapterRow: Identifiable, Equatable {
    let id: Int
    let novel: Int
    let idx: Int
    let num: String
    let title: String
    let url: String
    let volume: String
    let date: String
    var read: Bool
    var saved: Bool
    /// kept by the site for subscribers
    var locked: Bool = false

    init(row: [String: Any]) {
        id = row.int("id"); novel = row.int("novel"); idx = row.int("idx"); num = row.str("num"); title = row.str("title")
        url = row.str("url"); volume = row.str("volume"); date = row.str("date"); read = row.int("read") != 0; saved = row.int("saved") != 0
        locked = row.int("locked") != 0
    }

    /// «الفصل 680» when the site numbers it, otherwise its place in the list.
    /// Side stories and prefaces come from the site with no number (or 0): they are shown by their title alone.
    var numbered: Bool { !num.isEmpty && num != "0" }
    var label: String { numbered ? "الفصل \(num)" : (title.isEmpty ? "فصل إضافي" : title) }
    var line: String { numbered && !title.isEmpty ? "\(label): \(title)" : label }
}

struct ChapterText {
    var title: String
    var paras: [String]
    var removed: Int
    var words: Int { paras.reduce(0) { $0 + $1.split(whereSeparator: { $0 == " " || $0 == "\n" }).count } }
}

enum NovelError: LocalizedError {
    case unknownSite, blocked, empty
    case network(String)
    case parse(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unknownSite: return "هذا الموقع مو مضاف في جليس للحين"
        case .blocked: return "الموقع طلب تحقق أو حجب الطلب"
        case .empty: return "الصفحة وصلت بدون نص الفصل"
        case .network(let m): return "تعذّر الاتصال بالموقع: \(m)"
        case .parse(let m): return "ما قدرت أقرأ الصفحة (\(m))"
        case .message(let m): return m
        }
    }
}

// MARK: - downloading pages

enum Fetcher {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.httpAdditionalHeaders = ["Accept-Language": "ar,en;q=0.8"]
        return URLSession(configuration: c)
    }()

    /// The page as text. One quiet second try on a connection failure; never on a refusal.
    static func html(_ address: String, method: String = "GET", json: Any? = nil, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: address) else { throw NovelError.network("رابط غير صالح") }
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        // a site definition's fetch step (README «Fetch steps»): a POST with a JSON body, or extra headers
        if method.uppercased() == "POST" {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            if let j = json { req.httpBody = try? JSONSerialization.data(withJSONObject: j) }
            if let host = url.host, let scheme = url.scheme { req.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin") }
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var last: Error = NovelError.network("")
        var gated = false
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 900_000_000) }
            do {
                let (data, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 403 || code == 429 || code == 503 {
                    // Cloudflare's check (only when the page really is its check): once, inside Jalees, then the same
                    // request again with its cookies. A plain refusal (a locked chapter) stays a refusal.
                    let head = String(decoding: data.prefix(6000), as: UTF8.self).lowercased()
                    let challenge = head.contains("just a moment") || head.contains("cf-chl") || head.contains("challenge-platform") || head.contains("attention required")
                    if challenge, !gated, code != 429, await SiteGate.pass(url) { gated = true; continue }
                    if code == 403, !challenge { throw NovelError.message("الفصل مقفل في الموقع (للمشتركين أو لتطبيق الموقع)") }
                    throw NovelError.blocked
                }
                guard (200..<300).contains(code) else { throw NovelError.network("الموقع ردّ بالرمز \(code)") }
                return String(decoding: data, as: UTF8.self)
            } catch let e as NovelError {
                throw e
            } catch {
                last = NovelError.network(error.localizedDescription)
            }
        }
        throw last
    }
}

// MARK: - reading pages (the site definitions in www/reader/sources.js)

/// A web view that is never shown: it only gives sources.js a real page parser.
@MainActor
final class SourceEngine: NSObject, WKNavigationDelegate {
    static let shared = SourceEngine()

    private var web: WKWebView?
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func boot() {
        guard web == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(AppSchemeHandler(), forURLScheme: AppSchemeHandler.scheme)
        // the book search (lookup.js) asks Swift to fetch other sites for it
        cfg.userContentController.addScriptMessageHandler(NetReply(), contentWorld: .page, name: "net")
        let w = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: cfg)
        w.navigationDelegate = self
        w.isHidden = true
        web = w
        attach(w)
        if let u = URL(string: AppSchemeHandler.scheme + "://app/reader/engine.html") { w.load(URLRequest(url: u)) }
    }

    /// Inside the app's main window, so the system never suspends its scripts (tried again until there is one).
    private func attach(_ w: WKWebView) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let win = scenes.compactMap(\.keyWindow).first ?? scenes.flatMap(\.windows).first { $0.rootViewController != nil }
        if let win = win { win.insertSubview(w, at: 0); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if w.window == nil { self?.attach(w) } }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // the definitions downloaded from the repository (SiteRepo) go after the app's own, and take their place
        let extra = SiteRepo.scripts()
        guard !extra.isEmpty else { markReady(); return }
        var left = extra.count
        for js in extra {
            webView.evaluateJavaScript("(function(){try{" + js + "
}catch(e){}})();1") { [weak self] _, _ in
                left -= 1
                if left == 0 { self?.markReady() }
            }
        }
    }

    private func markReady() {
        ready = true
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    /// After the repository changed: the page again, with the new definitions.
    func restart() {
        guard let w = web else { return }
        ready = false
        w.reload()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.reload()
    }

    private func waitReady() async {
        boot()
        if ready { return }
        // never wait for good: after 8 seconds the caller hears that the engine is not ready
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self = self, !self.ready else { return }
            let w = self.waiters
            self.waiters = []
            w.forEach { $0.resume() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiters.append(c) }
        timer.cancel()
    }

    private func call(_ body: String, _ args: [String: Any]) async throws -> Any? {
        await waitReady()
        guard ready, let web = web else { throw NovelError.message("محرّك المواقع ما اشتغل، حاول مرة ثانية") }
        return await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            web.jalees(body, args) { v in c.resume(returning: v) }
        }
    }

    /// Runs a function of the book search (lookup.js) and waits for its answer.
    func lookup(_ body: String, _ args: [String: Any]) async -> Any? {
        try? await call(body, args)
    }

    /// Whether the address is a novel's own page (otherwise it is one of its chapters).
    func isSeries(_ site: String, _ url: String) async -> Bool {
        let v = try? await call("return SourceIsSeries(site, url)", ["site": site, "url": url])
        return (v as? Bool) ?? true
    }

    /// Which definition reads this address, or nil when no site matches.
    func site(for url: String) async -> String? {
        let v = try? await call("return SourceFor(url)", ["url": url])
        return v as? String
    }

    /// The sites that can be browsed (their newest and most read novels, and a search).
    func list() async -> [[String: Any]] {
        ((try? await call("return SourceList()", [:])) as? [[String: Any]]) ?? []
    }

    /// One page of a site's novels: «latest», «popular» or «search».
    func browse(_ site: String, kind: String, page: Int, query: String) async throws -> (items: [[String: Any]], more: Bool) {
        guard let u = try await call("return SourceBrowseURL(site, kind, page, q)", ["site": site, "kind": kind, "page": page, "q": query]) as? String, !u.isEmpty else {
            throw NovelError.unknownSite
        }
        let html = try await Fetcher.html(u)
        let r = (try await run(site, "browse", html: html, url: u) as? [String: Any]) ?? [:]
        return ((r["items"] as? [[String: Any]]) ?? [], (r["next"] as? Bool) ?? false)
    }

    /// Runs one function of a site definition over a downloaded page.
    func run(_ site: String, _ fn: String, html: String, url: String) async throws -> Any {
        let v = try await call("return SourceRun(site, fn, html, url)", ["site": site, "fn": fn, "html": html, "url": url])
        if let d = v as? [String: Any], let e = d["error"] as? String {
            if e == "blocked" { throw NovelError.blocked }
            throw NovelError.parse((d["detail"] as? String) ?? e)
        }
        guard let out = v else { throw NovelError.parse("empty") }
        return out
    }
}

// MARK: - the novels shelf

@MainActor
final class Novels: ObservableObject {
    static let shared = Novels()

    @Published private(set) var list: [Novel] = []
    private var loading: [Int: Task<ChapterText, Error>] = [:]
    private var ahead: Task<Void, Never>?
    private let db = DB.shared

    private init() { reload() }

    func reload() {
        list = db.query("SELECT * FROM novels ORDER BY COALESCE(opened, added) DESC").map(Novel.init(row:))
    }

    func novel(_ id: Int) -> Novel? {
        db.query("SELECT * FROM novels WHERE id=?", [id]).first.map(Novel.init(row:))
    }

    func chapters(_ novel: Int) -> [ChapterRow] {
        db.query("""
        SELECT c.*, (SELECT 1 FROM texts t WHERE t.chapter = c.id) AS saved
        FROM chapters c WHERE c.novel=? ORDER BY c.idx
        """, [novel]).map(ChapterRow.init(row:))
    }

    func readCount(_ novel: Int) -> Int {
        db.query("SELECT COUNT(*) AS n FROM chapters WHERE novel=? AND read=1", [novel]).first?.int("n") ?? 0
    }

    // MARK: adding and refreshing

    func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        return s
    }

    struct Added {
        let novel: Novel
        /// the chapter to open when the link was a chapter's
        let openIndex: Int?
    }

    /// Reads the novel's page and its whole chapter list, then saves both. A chapter's link works too: the novel is
    /// found from it and `openIndex` points at that chapter. `progress` gets a short Arabic status line.
    func add(url raw: String, progress: @escaping (String) -> Void) async throws -> Added {
        var url = clean(raw)
        // a site Jalees has no definition for is read the general way (sites/generic.js, س17.4)
        guard url.hasPrefix("http") else { throw NovelError.unknownSite }
        let site = await SourceEngine.shared.site(for: url) ?? "generic"
        var chapterURL: String?
        if !(await SourceEngine.shared.isSeries(site, url)) {
            progress("أدوّر على صفحة الرواية من الفصل")
            let page = try await Fetcher.html(url)
            guard let s = try await SourceEngine.shared.run(site, "seriesUrl", html: page, url: url) as? String, !s.isEmpty else { throw NovelError.parse("series link") }
            chapterURL = url
            url = clean(s)
        }
        let openAt: (Int) -> Int? = { [db] novel in
            guard let c = chapterURL else { return nil }
            return db.query("SELECT idx FROM chapters WHERE novel=? AND url=?", [novel, c]).first?.int("idx")
        }
        if let have = db.query("SELECT * FROM novels WHERE url=?", [url]).first {
            let n = Novel(row: have)
            return Added(novel: n, openIndex: openAt(n.id))
        }
        progress("أقرأ صفحة الرواية")
        let page = try await Fetcher.html(url)
        let info: [String: Any]
        do {
            guard let i = try await SourceEngine.shared.run(site, "series", html: page, url: url) as? [String: Any] else { throw NovelError.parse("series") }
            info = i
        } catch where site == "generic" {
            throw NovelError.message("جليس ما يعرف هالموقع، وحاول يقرأه لحاله وما قدر. جرّب رابط صفحة الرواية نفسها (اللي فيها قائمة الفصول).")
        }
        let title = (info["title"] as? String) ?? ""
        guard !title.isEmpty else { throw NovelError.parse("title") }
        let rows = try await allRows(site: site, first: (info["rows"] as? [[String: Any]]) ?? [], pages: (info["listPages"] as? [String]) ?? [], progress: progress)
        guard !rows.isEmpty else { throw NovelError.empty }

        var id = 0
        db.transaction {
            id = Int(db.run("INSERT INTO novels(source,url,title,author,cover,summary,status,total,added,updated,translator,genres) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                            [site, url, title, info["author"] as? String, info["cover"] as? String, info["summary"] as? String,
                             info["status"] as? String, rows.count, Date().timeIntervalSince1970, Date().timeIntervalSince1970,
                             info["translator"] as? String, ((info["genres"] as? [String]) ?? []).joined(separator: "|")]))
            for (i, r) in rows.enumerated() { insert(r, novel: id, idx: i) }
        }
        reload()
        guard let n = novel(id) else { throw NovelError.parse("save") }
        // your server follows it too
        if ServerLink.isOn { let u = url; Task { _ = try? await ServerLink.follow([u]) } }
        return Added(novel: n, openIndex: openAt(id))
    }

    // MARK: the library side

    /// Notes that a chapter was opened (the «السجل» tab); the same chapter again within the hour only moves its time.
    func logHistory(novel: Int, chapter: Int) {
        let now = Date().timeIntervalSince1970
        if let last = db.query("SELECT id, chapter, at FROM history ORDER BY at DESC LIMIT 1").first, last.int("chapter") == chapter, now - last.dbl("at") < 3600 {
            db.run("UPDATE history SET at=? WHERE id=?", [now, last.int("id")])
        } else {
            db.run("INSERT INTO history(novel, chapter, at) VALUES(?,?,?)", [novel, chapter, now])
        }
    }

    func link(_ novel: Int, book: String) {
        db.run("UPDATE novels SET book=? WHERE id=?", [book, novel])
        reload()
    }

    /// What the library shows for this novel: counts, where you are, and whether more chapters will come.
    func stats(_ novel: Int) -> [String: Any] {
        guard let n = self.novel(novel) else { return [:] }
        let total = db.query("SELECT COUNT(*) AS n FROM chapters WHERE novel=?", [novel]).first?.int("n") ?? 0
        let read = db.query("SELECT COUNT(*) AS n FROM chapters WHERE novel=? AND read=1", [novel]).first?.int("n") ?? 0
        var out: [String: Any] = ["book": n.book, "total": total, "read": read, "unread": max(0, total - read), "ongoing": !n.complete]
        if n.curChapter != 0, let row = db.query("SELECT * FROM chapters WHERE id=?", [n.curChapter]).first {
            let c = ChapterRow(row: row)
            out["cur"] = c.idx
            out["curLabel"] = c.label
        }
        return out
    }

    // MARK: backup (inside Jalees's backup file): each novel, its chapter list, what was read and where you stopped.
    // Chapter text is not included: it comes back from the site when opened.

    func exportAll() -> [[String: Any]] {
        db.query("SELECT * FROM novels WHERE source != 'sample'").map { n in
            let id = n.int("id")
            let chs = db.query("SELECT idx,num,title,url,volume,date,read FROM chapters WHERE novel=? ORDER BY idx", [id]).map { c -> [Any] in
                [c.int("idx"), c.str("num"), c.str("title"), c.str("url"), c.str("volume"), c.str("date"), c.int("read")]
            }
            let cur = n.int("cur_chapter")
            let curURL = cur == 0 ? "" : (db.query("SELECT url FROM chapters WHERE id=?", [cur]).first?.str("url") ?? "")
            return ["source": n.str("source"), "url": n.str("url"), "title": n.str("title"), "author": n.str("author"), "cover": n.str("cover"),
                    "summary": n.str("summary"), "status": n.str("status"), "book": n.str("book"), "translator": n.str("translator"),
                    "genres": n.str("genres"), "added": n.dbl("added"), "curURL": curURL, "curP": n.int("cur_p"), "curO": n.dbl("cur_o"), "chapters": chs]
        }
    }

    /// Restores novels from a backup; a novel already here (same address) keeps its own data.
    func importAll(_ list: [[String: Any]]) {
        for n in list {
            let url = n["url"] as? String ?? ""
            guard !url.isEmpty, db.query("SELECT id FROM novels WHERE url=?", [url]).isEmpty else { continue }
            let chs = (n["chapters"] as? [[Any]]) ?? []
            db.transaction {
                let id = Int(db.run("INSERT INTO novels(source,url,title,author,cover,summary,status,total,added,updated,book,translator,genres) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                                    [n["source"] as? String ?? "", url, n["title"] as? String ?? "", n["author"] as? String, n["cover"] as? String,
                                     n["summary"] as? String, n["status"] as? String, chs.count, (n["added"] as? Double) ?? Date().timeIntervalSince1970,
                                     Date().timeIntervalSince1970, n["book"] as? String, n["translator"] as? String, n["genres"] as? String]))
                for c in chs where c.count >= 7 {
                    db.run("INSERT OR IGNORE INTO chapters(novel,idx,num,title,url,volume,date,read) VALUES(?,?,?,?,?,?,?,?)",
                           [id, NovelBridge.num(c[0]), c[1] as? String, c[2] as? String, c[3] as? String ?? "", c[4] as? String, c[5] as? String, NovelBridge.num(c[6])])
                }
                if let cu = n["curURL"] as? String, !cu.isEmpty, let ch = db.query("SELECT id FROM chapters WHERE novel=? AND url=?", [id, cu]).first {
                    db.run("UPDATE novels SET cur_chapter=?, cur_p=?, cur_o=? WHERE id=?", [ch.int("id"), NovelBridge.num(n["curP"]), (n["curO"] as? Double) ?? 0, id])
                }
            }
        }
        reload()
    }

    func setRead(_ ids: [Int], _ read: Bool) {
        guard !ids.isEmpty else { return }
        db.transaction { for i in ids { db.run("UPDATE chapters SET read=? WHERE id=?", [read, i]) } }
    }

    /// Removes the saved text (the chapter stays in the list and comes back from the site when opened).
    func undownload(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        db.transaction { for i in ids { db.run("DELETE FROM texts WHERE chapter=?", [i]) } }
    }

    func chapter(_ id: Int) -> ChapterRow? {
        db.query("SELECT c.*, (SELECT 1 FROM texts t WHERE t.chapter = c.id) AS saved FROM chapters c WHERE c.id=?", [id]).first.map(ChapterRow.init(row:))
    }

    func insert(_ r: [String: Any], novel: Int, idx: Int, found: Double? = nil) {
        db.run("INSERT OR IGNORE INTO chapters(novel,idx,num,title,url,volume,date,found,locked) VALUES(?,?,?,?,?,?,?,?,?)",
               [novel, idx, r["num"] as? String, r["title"] as? String, (r["url"] as? String) ?? "", r["volume"] as? String, r["date"] as? String, found,
                (r["locked"] as? Bool) == true ? 1 : 0])
    }

    /// Every list page, four at a time, returned oldest chapter first.
    func allRows(site: String, first: [[String: Any]], pages: [String], progress: @escaping (String) -> Void) async throws -> [[String: Any]] {
        var newestFirst = first
        var seen = Set(first.compactMap { $0["url"] as? String })
        var next = 1
        while next < pages.count {
            let batch = Array(next..<min(next + 4, pages.count))
            progress("قائمة الفصول: صفحة \(batch.last! + 1) من \(pages.count)")
            var got: [Int: String] = [:]
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in batch {
                    let u = pages[i]
                    group.addTask {
                        let h = try await Fetcher.html(u)
                        return (i, h)
                    }
                }
                for try await (i, h) in group { got[i] = h }
            }
            for i in batch {
                guard let h = got[i] else { continue }
                let rows = (try await SourceEngine.shared.run(site, "list", html: h, url: pages[i]) as? [[String: Any]]) ?? []
                for r in rows {
                    guard let u = r["url"] as? String, !seen.contains(u) else { continue }
                    seen.insert(u)
                    newestFirst.append(r)
                }
            }
            next += 4
        }
        return newestFirst.reversed()
    }

    /// Looks at the newest list page and appends chapters that were not known. Returns how many arrived.
    func refresh(_ novel: Novel) async throws -> Int {
        guard novel.source != "sample", novel.source != "archive" else { return 0 }
        let page = try await Fetcher.html(novel.url)
        guard let info = try await SourceEngine.shared.run(novel.source, "series", html: page, url: novel.url) as? [String: Any] else { return 0 }
        let rows = (info["rows"] as? [[String: Any]]) ?? []
        let known = Set(db.query("SELECT url FROM chapters WHERE novel=?", [novel.id]).map { $0.str("url") })
        let fresh = rows.filter { !known.contains(($0["url"] as? String) ?? "") }.reversed()
        var idx = (db.query("SELECT MAX(idx) AS m FROM chapters WHERE novel=?", [novel.id]).first?.int("m") ?? -1) + 1
        let now = Date().timeIntervalSince1970
        db.transaction {
            for r in fresh { insert(r, novel: novel.id, idx: idx, found: now); idx += 1 }
            db.run("UPDATE novels SET total=(SELECT COUNT(*) FROM chapters WHERE novel=?), updated=?, status=? WHERE id=?",
                   [novel.id, Date().timeIntervalSince1970, (info["status"] as? String) ?? novel.status, novel.id])
        }
        reload()
        return fresh.count
    }

    /// Looks for new chapters in every novel from a site, three at a time. Returns how many arrived.
    func checkAll(progress: @escaping (String) -> Void) async -> Int {
        let list = self.list.filter { $0.source != "sample" && $0.source != "epub" && $0.source != "archive" }
        var found = 0, done = 0
        await withTaskGroup(of: (Int, Int).self) { group in
            var it = list.makeIterator()
            func next() {
                guard let n = it.next() else { return }
                group.addTask { @MainActor in (n.id, (try? await Novels.shared.refresh(n)) ?? 0) }
            }
            for _ in 0..<3 { next() }
            for await (id, k) in group {
                done += 1
                found += k
                if k > 0 { NovelBridge.sync(id) }
                progress("أفحص رواياتك: \(done) من \(list.count)")
                next()
            }
        }
        db.set("updates.checked", String(Date().timeIntervalSince1970))
        return found
    }

    /// Where a character is first named: the earliest chapter whose text holds the name (or alias) as a word, also after
    /// و ف ب ل ك. Web novels: among the chapters saved on the phone (`sure` when every chapter before it is saved).
    /// EPUB: read from the file. Words the replacement rules turn into the name count too.
    func firstMention(_ novel: Int, names: [String]) async -> (num: Int, sure: Bool)? {
        var keys = names.map { $0.replacingOccurrences(of: "ـ", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 1 }
        guard !keys.isEmpty, let n = self.novel(novel) else { return nil }
        for r in Replacer.rules(String(novel)) + Replacer.rules("all") where !r.from.isEmpty && keys.contains(where: { r.to.contains($0) }) { keys.append(r.from) }
        let alt = keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let letters = "\\u0600-\\u06FFA-Za-z"
        guard let re = try? NSRegularExpression(pattern: "(^|[^\(letters)])[وفبلك]?(?:\(alt))(?=$|[^\(letters)])") else { return nil }
        let terms = keys
        let found: (Int, Bool)? = await Task.detached(priority: .userInitiated) { () -> (Int, Bool)? in
            func has(_ s: String) -> Bool {
                let t = s.replacingOccurrences(of: "ـ", with: "")
                return re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
            }
            let db = DB.shared
            let rows = db.query("SELECT id, idx, num, url FROM chapters WHERE novel=? ORDER BY idx", [novel])
            func num(_ r: [String: Any]) -> Int { Int(r.str("num")) ?? (r.int("idx") + 1) }
            if n.source == "epub" {
                for r in rows {
                    if let t = try? EpubStore.rawText(url: r.str("url")), has(t) { return (num(r), true) }
                }
                return nil
            }
            let like = terms.map { _ in "t.paras LIKE ?" }.joined(separator: " OR ")
            let hits = db.query("SELECT c.idx, c.num, t.paras FROM chapters c JOIN texts t ON t.chapter=c.id WHERE c.novel=? AND (\(like)) ORDER BY c.idx",
                                ([novel] as [Any?]) + terms.map { "%" + $0 + "%" })
            guard let first = hits.first(where: { has($0.str("paras")) }) else { return nil }
            let missing = db.query("SELECT COUNT(*) AS k FROM chapters c WHERE c.novel=? AND c.idx < ? AND NOT EXISTS (SELECT 1 FROM texts t WHERE t.chapter=c.id)",
                                   [novel, first.int("idx")]).first?.int("k") ?? 1
            return (num(first), missing == 0)
        }.value
        return found.map { (num: $0.0, sure: $0.1) }
    }

    func delete(_ novel: Novel) {
        db.run("DELETE FROM novels WHERE id=?", [novel.id])
        reload()
    }

    // MARK: chapter text

    func stored(_ chapter: Int) -> ChapterText? {
        guard let row = db.query("SELECT title,paras,removed FROM texts WHERE chapter=?", [chapter]).first,
              let data = row.str("paras").data(using: .utf8),
              let paras = (try? JSONSerialization.jsonObject(with: data)) as? [String], !paras.isEmpty else { return nil }
        return ChapterText(title: row.str("title"), paras: paras, removed: row.int("removed"))
    }

    /// The chapter's text: the saved copy when there is one, otherwise from the site (and then saved).
    func text(_ ch: ChapterRow, source: String, refresh: Bool = false) async throws -> ChapterText {
        if !refresh, let t = stored(ch.id) { return t }
        if let running = loading[ch.id] { return try await running.value }
        let task = Task<ChapterText, Error> { [db] in
            let t: ChapterText
            if source == "sample" {
                t = Sample.text(ch)
            } else if source == "epub" {
                t = try await EpubStore.text(ch)
            } else if source == "archive" {
                throw NovelError.message("هذا الفصل مو في الأرشيف المستورد")
            } else {
                var html = try await Fetcher.html(ch.url)
                guard var d = try await SourceEngine.shared.run(source, "chapter", html: html, url: ch.url) as? [String: Any] else { throw NovelError.parse("chapter") }
                // fetch steps: the definition asks for another address (or a POST) and reads its answer
                var hops = 0
                while let f = d["fetch"] as? [String: Any], let u = f["url"] as? String, hops < 3 {
                    hops += 1
                    html = try await Fetcher.html(u, method: (f["method"] as? String) ?? "GET", json: f["json"], headers: (f["headers"] as? [String: String]) ?? [:])
                    guard let next = try await SourceEngine.shared.run(source, "chapter", html: html, url: ch.url) as? [String: Any] else { throw NovelError.parse("chapter") }
                    d = next
                }
                let paras = (d["paras"] as? [String]) ?? []
                guard !paras.isEmpty else { throw NovelError.empty }
                t = ChapterText(title: (d["title"] as? String) ?? "", paras: paras, removed: (d["removed"] as? Int) ?? 0)
            }
            let json = String(data: (try? JSONSerialization.data(withJSONObject: t.paras)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            db.run("INSERT INTO texts(chapter,title,paras,removed,fetched) VALUES(?,?,?,?,?) ON CONFLICT(chapter) DO UPDATE SET title=excluded.title, paras=excluded.paras, removed=excluded.removed, fetched=excluded.fetched",
                   [ch.id, t.title, json, t.removed, Date().timeIntervalSince1970])
            db.run("UPDATE chapters SET words=? WHERE id=?", [t.words, ch.id])
            return t
        }
        loading[ch.id] = task
        defer { loading[ch.id] = nil }
        do {
            return try await task.value
        } catch {
            // missing or broken on the main site: the same chapter from a backup source, when there is one (س63)
            if source != "epub", source != "archive", source != "sample", !mirrors(ch.novel).isEmpty,
               let t = try? await textFromMirror(ch, novel: ch.novel) { return t }
            // and from your server's archive (ServerLink), when one is set
            if source != "epub", source != "sample", ServerLink.isOn, let t = try? await ServerLink.chapter(ch.url) {
                keep(ch, t)
                return t
            }
            throw error
        }
    }

    /// Saves a chapter's text got some other way (the server's archive).
    func keep(_ ch: ChapterRow, _ t: ChapterText) {
        let json = String(data: (try? JSONSerialization.data(withJSONObject: t.paras)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        db.run("INSERT INTO texts(chapter,title,paras,removed,fetched) VALUES(?,?,?,?,?) ON CONFLICT(chapter) DO UPDATE SET title=excluded.title, paras=excluded.paras, removed=excluded.removed, fetched=excluded.fetched",
               [ch.id, t.title, json, t.removed, Date().timeIntervalSince1970])
        db.run("UPDATE chapters SET words=? WHERE id=?", [t.words, ch.id])
    }

    /// Quietly gets the next few chapters ready so turning to them is instant.
    func prepare(after index: Int, in chapters: [ChapterRow], source: String, count: Int = 5) {
        ahead?.cancel()
        let wanted = chapters.dropFirst(index + 1).prefix(count).filter { !$0.saved }
        guard !wanted.isEmpty else { return }
        ahead = Task { [weak self] in
            for ch in wanted {
                if Task.isCancelled { return }
                _ = try? await self?.text(ch, source: source)
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    // MARK: place and progress

    func savePlace(novel: Int, chapter: Int, p: Int, o: Double) {
        db.run("UPDATE novels SET cur_chapter=?, cur_p=?, cur_o=?, opened=? WHERE id=?", [chapter, p, o, Date().timeIntervalSince1970, novel])
        db.run("UPDATE chapters SET pos_p=?, pos_o=? WHERE id=?", [p, o, chapter])
    }

    /// Where you stopped in a chapter, or nil when you never got past its start.
    func place(in chapter: Int) -> (p: Int, o: Double)? {
        guard let r = db.query("SELECT pos_p, pos_o FROM chapters WHERE id=?", [chapter]).first else { return nil }
        let p = r.int("pos_p"), o = r.dbl("pos_o")
        return p > 0 || o > 0.02 ? (p, o) : nil
    }

    func markRead(_ chapter: Int, _ read: Bool = true) {
        db.run("UPDATE chapters SET read=? WHERE id=?", [read, chapter])
    }

    /// Marks everything before `idx` as read (used by «ابدأ من هنا»).
    func markReadBefore(novel: Int, idx: Int) {
        db.run("UPDATE chapters SET read = CASE WHEN idx < ? THEN 1 ELSE 0 END WHERE novel=?", [idx, novel])
    }
}

// MARK: - a built-in novel for screenshots and tests (never created on a normal launch)

enum Sample {
    static func ensure() -> Novel? {
        let db = DB.shared
        if let row = db.query("SELECT * FROM novels WHERE source='sample'").first { return Novel(row: row) }
        var id = 0
        db.transaction {
            id = Int(db.run("INSERT INTO novels(source,url,title,author,cover,summary,status,total,added) VALUES('sample','sample://novel','حارس المكتبة الأخيرة','جليس','','رواية قصيرة تجريبية تجي مع التطبيق عشان نجرّب القارئ بدون إنترنت.','مكتملة',40,?)",
                            [Date().timeIntervalSince1970]))
            let names = ["الباب الذي لا يُفتح", "رائحة الورق القديم", "خريطة بلا شمال", "ضيف منتصف الليل", "الرف السابع"]
            for i in 0..<40 {
                db.run("INSERT INTO chapters(novel,idx,num,title,url) VALUES(?,?,?,?,?)", [id, i, String(i + 1), names[i % names.count], "sample://chapter/\(i + 1)"])
            }
        }
        return db.query("SELECT * FROM novels WHERE id=?", [id]).first.map(Novel.init(row:))
    }

    static func text(_ ch: ChapterRow) -> ChapterText {
        let root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("www/reader/sample.json")
        let base = ((try? JSONSerialization.jsonObject(with: (try? Data(contentsOf: root)) ?? Data())) as? [String]) ?? ["نص تجريبي."]
        var paras: [String] = []
        for i in 0..<(base.count * 3) { paras.append(base[(i + ch.idx) % base.count]) }
        return ChapterText(title: ch.title, paras: paras, removed: 0)
    }
}

/// Fetches for the book search page: {url, ua, as} in, {ok, status, text} out.
final class NetReply: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let o = message.body as? [String: Any] else { replyHandler(["ok": false, "status": 0], nil); return }
        Net.fetch(o) { r in replyHandler(r, nil) }
    }
}
