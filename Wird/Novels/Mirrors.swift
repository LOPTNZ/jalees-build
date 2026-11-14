import Foundation

/// The same novel on other sites (answers-round2 س29، س29.1، س56، س63): backup sources you add, used for one chapter
/// when you ask («بدّل المصدر لهالفصل») and on their own when a chapter is missing or broken on the main site; and
/// moving a novel to another site for good, keeping what you read, saved and highlighted (chapters matched by number).
extension Novels {
    struct Mirror { let source: String; let url: String }

    func mirrors(_ novel: Int) -> [Mirror] {
        DB.shared.query("SELECT source, url FROM mirrors WHERE novel=?", [novel]).map { Mirror(source: $0.str("source"), url: $0.str("url")) }
    }

    /// The novel's page and its whole chapter list on a site (oldest first).
    func readSeries(_ url: String, progress: @escaping (String) -> Void) async throws -> (site: String, info: [String: Any], rows: [[String: Any]]) {
        var u = clean(url)
        guard let site = await SourceEngine.shared.site(for: u) else { throw NovelError.unknownSite }
        if !(await SourceEngine.shared.isSeries(site, u)) {
            let page = try await Fetcher.html(u)
            guard let s = try await SourceEngine.shared.run(site, "seriesUrl", html: page, url: u) as? String, !s.isEmpty else { throw NovelError.parse("series link") }
            u = clean(s)
        }
        progress("أقرأ صفحة الرواية")
        let page = try await Fetcher.html(u)
        guard let info = try await SourceEngine.shared.run(site, "series", html: page, url: u) as? [String: Any] else { throw NovelError.parse("series") }
        let rows = try await allRows(site: site, first: (info["rows"] as? [[String: Any]]) ?? [], pages: (info["listPages"] as? [String]) ?? [], progress: progress)
        guard !rows.isEmpty else { throw NovelError.empty }
        var i = info
        i["url"] = u
        return (site, i, rows)
    }

    /// Adds a backup source; returns its site's name.
    func addMirror(_ n: Novel, url: String, progress: @escaping (String) -> Void) async throws -> String {
        let r = try await readSeries(url, progress: progress)
        let u = (r.info["url"] as? String) ?? url
        guard u != n.url else { throw NovelError.message("هذا نفس المصدر الأساسي") }
        DB.shared.run("INSERT OR REPLACE INTO mirrors(novel, source, url) VALUES(?,?,?)", [n.id, r.site, u])
        cacheMirrorRows(n.id, u, r.rows)
        return await SourceEngine.shared.list().first { ($0["id"] as? String) == r.site }?["name"] as? String ?? r.site
    }

    func removeMirror(_ novel: Int, url: String) {
        DB.shared.run("DELETE FROM mirrors WHERE novel=? AND url=?", [novel, url])
        DB.shared.set("mirror.rows.\(novel).\(url)", "")
    }

    private func cacheMirrorRows(_ novel: Int, _ url: String, _ rows: [[String: Any]]) {
        let slim = rows.map { ["num": $0["num"] as? String ?? "", "url": $0["url"] as? String ?? "", "title": $0["title"] as? String ?? ""] }
        let o: [String: Any] = ["at": Date().timeIntervalSince1970, "rows": slim]
        if let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) { DB.shared.set("mirror.rows.\(novel).\(url)", s) }
    }

    /// The mirror's chapter list, from the phone when it is under a day old and has the number wanted.
    private func mirrorRows(_ novel: Int, _ m: Mirror, want num: String) async throws -> [[String: String]] {
        if let s = DB.shared.get("mirror.rows.\(novel).\(m.url)"), let d = s.data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let rows = o["rows"] as? [[String: String]],
           Date().timeIntervalSince1970 - ((o["at"] as? Double) ?? 0) < 86_400, rows.contains(where: { Self.sameNum($0["num"] ?? "", num) }) {
            return rows
        }
        let r = try await readSeries(m.url) { _ in }
        cacheMirrorRows(novel, m.url, r.rows)
        return r.rows.map { ["num": $0["num"] as? String ?? "", "url": $0["url"] as? String ?? "", "title": $0["title"] as? String ?? ""] }
    }

    static func sameNum(_ a: String, _ b: String) -> Bool {
        let x = a.filter(\.isNumber), y = b.filter(\.isNumber)
        guard !x.isEmpty, !y.isEmpty, let p = Int(x), let q = Int(y) else { return false }
        return p == q
    }

    /// One chapter from a backup source (the first that has its number); saved as this chapter's text.
    func textFromMirror(_ ch: ChapterRow, novel: Int, only: Mirror? = nil) async throws -> ChapterText {
        let list = only.map { [$0] } ?? mirrors(novel)
        guard !list.isEmpty else { throw NovelError.message("ما فيه مصادر احتياطية لهالرواية") }
        var lastError: Error = NovelError.message("ما لقيت الفصل \(ch.num) في المصادر الثانية")
        for m in list {
            do {
                let rows = try await mirrorRows(novel, m, want: ch.num)
                guard let row = rows.first(where: { Self.sameNum($0["num"] ?? "", ch.num) }), let u = row["url"], !u.isEmpty else { continue }
                let html = try await Fetcher.html(u)
                guard let d = try await SourceEngine.shared.run(m.source, "chapter", html: html, url: u) as? [String: Any],
                      let paras = d["paras"] as? [String], !paras.isEmpty else { continue }
                let t = ChapterText(title: (d["title"] as? String) ?? ch.title, paras: paras, removed: (d["removed"] as? Int) ?? 0)
                let json = String(data: (try? JSONSerialization.data(withJSONObject: t.paras)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
                DB.shared.run("INSERT INTO texts(chapter,title,paras,removed,fetched) VALUES(?,?,?,?,?) ON CONFLICT(chapter) DO UPDATE SET title=excluded.title, paras=excluded.paras, removed=excluded.removed, fetched=excluded.fetched",
                              [ch.id, t.title, json, t.removed, Date().timeIntervalSince1970])
                DB.shared.run("UPDATE chapters SET words=? WHERE id=?", [t.words, ch.id])
                DB.shared.set("chapter.source.\(ch.id)", m.source)
                return t
            } catch { lastError = error }
        }
        throw lastError
    }

    /// Moves the novel to another site for good. Chapters with the same number keep their id (so what you read,
    /// saved and highlighted stays); chapters only on the new site are added in order.
    func move(_ n: Novel, to url: String, progress: @escaping (String) -> Void) async throws {
        let r = try await readSeries(url, progress: progress)
        let newURL = (r.info["url"] as? String) ?? url
        if DB.shared.query("SELECT id FROM novels WHERE url=? AND id<>?", [newURL, n.id]).first != nil {
            throw NovelError.message("هذي الرواية مضافة من الموقع الثاني من قبل")
        }
        progress("أطابق الفصول")
        let old = chapters(n.id)
        let db = DB.shared
        db.transaction {
            var used = Set<Int>()
            for (i, row) in r.rows.enumerated() {
                let num = row["num"] as? String ?? ""
                if let c = old.first(where: { !used.contains($0.id) && Self.sameNum($0.num, num) }) {
                    used.insert(c.id)
                    db.run("UPDATE chapters SET idx=?, url=?, title=CASE WHEN title IS NULL OR title='' THEN ? ELSE title END, volume=?, date=?, locked=? WHERE id=?",
                           [i, row["url"] as? String ?? "", row["title"] as? String ?? "", row["volume"] as? String ?? "", row["date"] as? String ?? "",
                            (row["locked"] as? Bool) == true ? 1 : 0, c.id])
                } else {
                    insert(row, novel: n.id, idx: i)
                }
            }
            // what only the old site had goes after, in its own order
            var tail = r.rows.count
            for c in old where !used.contains(c.id) { db.run("UPDATE chapters SET idx=? WHERE id=?", [tail, c.id]); tail += 1 }
            db.run("UPDATE novels SET source=?, url=?, total=(SELECT COUNT(*) FROM chapters WHERE novel=?), updated=? WHERE id=?",
                   [r.site, newURL, n.id, Date().timeIntervalSince1970, n.id])
            // the old site becomes a backup source
            if n.source != "archive" && n.source != "epub" { db.run("INSERT OR REPLACE INTO mirrors(novel, source, url) VALUES(?,?,?)", [n.id, n.source, n.url]) }
        }
        reload()
    }
}
