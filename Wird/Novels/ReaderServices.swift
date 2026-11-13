import UIKit
import CoreText

private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

private func getData(_ url: URL) async throws -> (Data, Int) {
    var r = URLRequest(url: url, timeoutInterval: 25)
    r.setValue(ua, forHTTPHeaderField: "User-Agent")
    r.setValue("ar,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    let (d, resp) = try await URLSession.shared.data(for: r)
    return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
}

private func getJSON(_ url: URL) async throws -> Any {
    let (d, code) = try await getData(url)
    guard (200..<300).contains(code) else { throw NovelError.network("الرد \(code)") }
    return try JSONSerialization.jsonObject(with: d)
}

// MARK: - comments (kolnovel keeps them on its own comments server, readable without an account)

enum Comments {
    struct Result {
        let items: [[String: Any]]
        let total: Int
    }

    /// The commenter's number in this novel: given once, kept for good.
    static func number(novel: Int, author: String) -> Int {
        let db = DB.shared
        if let n = db.query("SELECT n FROM commenters WHERE novel=? AND author=?", [novel, author]).first?.int("n"), n > 0 { return n }
        let n = (db.query("SELECT MAX(n) AS m FROM commenters WHERE novel=?", [novel]).first?.int("m") ?? 0) + 1
        db.run("INSERT OR IGNORE INTO commenters(novel,author,n) VALUES(?,?,?)", [novel, author, n])
        return db.query("SELECT n FROM commenters WHERE novel=? AND author=?", [novel, author]).first?.int("n") ?? n
    }

    /// The chapter's comments kept on the phone (their times worked out again for now).
    static func saved(_ chapter: Int) -> Result? {
        guard let row = DB.shared.query("SELECT json, total FROM comments WHERE chapter=?", [chapter]).first,
              let d = row.str("json").data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
        func fresh(_ c: [String: Any]) -> [String: Any] {
            var o = c
            if let t = c["created"] as? String, !t.isEmpty { o["when"] = ago(t) }
            if let r = c["replies"] as? [[String: Any]] { o["replies"] = r.map(fresh) }
            return o
        }
        return Result(items: list.map(fresh), total: max(row.int("total"), list.count))
    }

    static func save(_ chapter: Int, _ items: [[String: Any]], total: Int) {
        guard let d = try? JSONSerialization.data(withJSONObject: items), let s = String(data: d, encoding: .utf8) else { return }
        DB.shared.run("INSERT INTO comments(chapter,json,total,at) VALUES(?,?,?,?) ON CONFLICT(chapter) DO UPDATE SET json=excluded.json, total=excluded.total, at=excluded.at",
                      [chapter, s, total, Date().timeIntervalSince1970])
    }

    /// Two lists of comments as one: each comment once, newest first.
    static func merge(_ a: [[String: Any]], _ b: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>(), out: [[String: Any]] = []
        for c in a + b {
            let id = (c["id"] as? String) ?? UUID().uuidString
            if seen.insert(id).inserted { out.append(c) }
        }
        return out.sorted { ((($0["created"] as? String) ?? "") > (($1["created"] as? String) ?? "")) }
    }

    /// Every comment of a chapter (up to 300), kept on the phone: for downloads.
    static func keepAll(chapterURL: String, chapter: Int, novel: Int) async {
        var all: [[String: Any]] = [], total = 0, page = 1
        while page <= 10 {
            guard let r = try? await load(chapterURL: chapterURL, page: page, novel: novel) else { break }
            all = merge(all, r.items)
            total = r.total
            if r.items.isEmpty || all.count >= total { break }
            page += 1
        }
        if let old = saved(chapter) { all = merge(all, old.items) }
        if !all.isEmpty || total == 0 { save(chapter, all, total: max(total, all.count)) }
    }

    private static let api = "https://cmtapi.kolnovel.com/api/collections/"

    private static func url(_ collection: String, _ q: [String: String]) -> URL? {
        var c = URLComponents(string: api + collection + "/records")
        c?.queryItems = q.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    /// The chapter's comments, newest first, 30 a page, each with its replies. Names are not public, so each shows as «قارئ».
    static func load(chapterURL: String, page: Int, novel: Int) async throws -> Result {
        guard let r = chapterURL.range(of: #"-(\d+)/?$"#, options: .regularExpression) else { return Result(items: [], total: 0) }
        let post = chapterURL[r].filter(\.isNumber)
        guard let eu = url("entities", ["filter": "wpPostId = \(post)", "perPage": "1"]),
              let ent = try await getJSON(eu) as? [String: Any],
              let e = (ent["items"] as? [[String: Any]])?.first, let eid = e["id"] as? String else { return Result(items: [], total: 0) }
        guard let cu = url("comments", ["filter": "entity = \"\(eid)\" && (parentId = \"\" || parentId = null)", "sort": "-created", "perPage": "30", "page": "\(page)"]),
              let list = try await getJSON(cu) as? [String: Any] else { return Result(items: [], total: 0) }
        let top = ((list["items"] as? [[String: Any]]) ?? []).filter { ($0["isDeleted"] as? Bool) != true }
        var replies: [String: [[String: Any]]] = [:]
        if !top.isEmpty {
            let f = top.compactMap { $0["id"] as? String }.map { "parentId = \"\($0)\"" }.joined(separator: " || ")
            if let ru = url("comments", ["filter": f, "sort": "created", "perPage": "200"]), let rl = try? await getJSON(ru) as? [String: Any] {
                for x in (rl["items"] as? [[String: Any]]) ?? [] where (x["isDeleted"] as? Bool) != true {
                    if let p = x["parentId"] as? String { replies[p, default: []].append(x) }
                }
            }
        }
        // the site keeps names private; each writer gets a number in this novel, the same in every reply and every
        // chapter, so a discussion can be followed
        func label(_ c: [String: Any]) -> String {
            let a = (c["author"] as? String) ?? ""
            return a.isEmpty ? "قارئ" : "قارئ \(number(novel: novel, author: a))"
        }
        let items: [[String: Any]] = top.map { c in
            var o = shape(c)
            o["who"] = label(c)
            o["replies"] = (replies[(c["id"] as? String) ?? ""] ?? []).map { x -> [String: Any] in
                var r = shape(x)
                r["who"] = label(x)
                return r
            }
            return o
        }
        let total = (list["totalItems"] as? Int) ?? items.count
        return Result(items: items, total: total)
    }

    private static func shape(_ c: [String: Any]) -> [String: Any] {
        ["id": (c["id"] as? String) ?? "", "created": (c["created"] as? String) ?? "",
         "who": "قارئ", "when": ago(c["created"] as? String ?? ""), "text": plainText(c["text"] ?? ""), "spoiler": (c["containsSpoiler"] as? Bool) ?? false]
    }

    /// The comments are rich text saved as JSON, in two editors' shapes (Lexical's {"root": …} and ProseMirror's
    /// {"type": "doc", "content": …}), sometimes as a string that holds that JSON. This keeps their words and line breaks.
    static func plainText(_ raw: Any) -> String {
        var obj: Any = raw
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("{") || t.hasPrefix("["), let d = t.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) else { return s }
            obj = j
        }
        func kids(_ n: [String: Any]) -> [[String: Any]]? { (n["children"] as? [[String: Any]]) ?? (n["content"] as? [[String: Any]]) }
        func kind(_ n: [String: Any]) -> String { ((n["type"] as? String) ?? "").lowercased() }
        func walk(_ n: [String: Any]) -> String {
            let type = kind(n)
            if type == "linebreak" || type == "hardbreak" { return "\n" }
            if let t = n["text"] as? String, kids(n) == nil { return t }
            if let k = kids(n) { return k.map(walk).joined() }
            // mentions, emoji and the like keep whatever words they carry
            if let a = n["attrs"] as? [String: Any] {
                for key in ["label", "text", "name", "emoji"] { if let t = a[key] as? String { return type == "mention" ? "@" + t : t } }
            }
            for key in ["value", "name", "emoji", "code"] { if let t = n[key] as? String { return t } }
            return ""
        }
        // lists and quotes hold paragraphs of their own
        let holders: Set<String> = ["bulletlist", "orderedlist", "list", "listitem", "blockquote", "quote"]
        func blocks(_ n: [String: Any]) -> [String] {
            guard let k = kids(n) else { return [walk(n)] }
            return k.flatMap { c -> [String] in holders.contains(kind(c)) && kids(c) != nil ? blocks(c) : [walk(c)] }
        }
        let root: [String: Any]
        if let d = obj as? [String: Any] { root = (d["root"] as? [String: Any]) ?? d }
        else if let a = obj as? [[String: Any]] { root = ["content": a] }
        else { return (raw as? String) ?? "" }
        return blocks(root).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func ago(_ s: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"
        guard let d = f.date(from: s) else { return "" }
        let r = RelativeDateTimeFormatter()
        r.locale = Locale(identifier: "ar@numbers=latn")
        r.unitsStyle = .full
        return r.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - a word's meaning, fetched by itself and editable afterwards

enum WordLookup {
    struct Result {
        var meaning = ""
        var translation = ""
    }

    /// The notebook's language codes (ar, en, ja, zh, ko…).
    static func language(of w: String) -> String {
        for s in w.unicodeScalars {
            switch s.value {
            case 0x0600...0x06FF, 0x0750...0x077F: return "ar"
            case 0x3040...0x30FF: return "ja"
            case 0xAC00...0xD7AF: return "ko"
            case 0x4E00...0x9FFF: return "zh"
            case 0x0400...0x04FF: return "ru"
            default: continue
            }
        }
        return "en"
    }

    static func find(_ word: String) async -> Result {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !w.isEmpty else { return Result() }
        var r = Result()
        if language(of: w) == "ar" {
            r.meaning = await arabicMeaning(w)
            if r.meaning.isEmpty, w.hasPrefix("ال"), w.count > 3 { r.meaning = await arabicMeaning(String(w.dropFirst(2))) }
            r.translation = await translate(w, to: "en")
        } else {
            r.translation = await translate(w, to: "ar")
            if language(of: w) == "en" { r.meaning = await englishMeaning(w) }
        }
        return r
    }

    private static func arabicMeaning(_ w: String) async -> String {
        var c = URLComponents(string: "https://ar.wiktionary.org/w/api.php")
        c?.queryItems = ["action": "query", "prop": "extracts", "explaintext": "1", "redirects": "1", "format": "json", "titles": w].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = c?.url, let j = try? await getJSON(u) as? [String: Any],
              let pages = (j["query"] as? [String: Any])?["pages"] as? [String: Any],
              let page = pages.values.first as? [String: Any], let ex = page["extract"] as? String else { return "" }
        let lines = ex.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("=") && $0.count > 3 }
        return lines.prefix(2).joined(separator: " ").prefix(260).description
    }

    private static func englishMeaning(_ w: String) async -> String {
        guard let q = w.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let u = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/" + q),
              let j = try? await getJSON(u) as? [[String: Any]], let first = j.first,
              let meanings = first["meanings"] as? [[String: Any]], let m = meanings.first,
              let defs = m["definitions"] as? [[String: Any]], let d = defs.first?["definition"] as? String else { return "" }
        return d
    }

    /// A short translation (Google's public translate endpoint).
    static func translate(_ text: String, to lang: String) async -> String {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        c?.queryItems = [URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"), URLQueryItem(name: "tl", value: lang),
                         URLQueryItem(name: "dt", value: "t"), URLQueryItem(name: "q", value: text)]
        guard let u = c?.url, let j = try? await getJSON(u) as? [Any], let parts = j.first as? [Any] else { return "" }
        return parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }
}

/// Apple's own dictionary panel for a word.
enum DeviceDictionary {
    static func show(_ word: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        top.present(UIReferenceLibraryViewController(term: word), animated: true)
    }
}

// MARK: - fonts the owner adds (a file, or a family from Google Fonts)

enum FontStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wird/fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func addFile(_ url: URL) throws -> UserFont {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let descs = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let d = descs.first,
              let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String else {
            throw Failure(errorDescription: "الملف ما هو خط يقدر جليس يقرأه")
        }
        let ext = url.pathExtension.lowercased().isEmpty ? "ttf" : url.pathExtension.lowercased()
        let name = UUID().uuidString.prefix(8) + "." + ext
        try data.write(to: dir.appendingPathComponent(String(name)), options: .atomic)
        let fmt = ext == "otf" ? "opentype" : (ext == "woff2" ? "woff2" : "truetype")
        let css = "@font-face{font-family:\"\(family)\";src:url(\"/userfonts/\(name)\") format(\"\(fmt)\");font-display:block}"
        return UserFont(family: family, css: css)
    }

    static func addGoogle(_ family: String) async throws -> UserFont {
        let q = family.replacingOccurrences(of: " ", with: "+")
        guard let u = URL(string: "https://fonts.googleapis.com/css2?family=\(q):wght@400;700&display=swap") else { throw Failure(errorDescription: "اسم غير صالح") }
        let (d, code) = try await getData(u)
        guard code == 200, var css = String(data: d, encoding: .utf8), css.contains("@font-face") else {
            throw Failure(errorDescription: "ما لقيت خط اسمه «\(family)» في Google Fonts")
        }
        let pattern = try NSRegularExpression(pattern: #"url\((https://fonts\.gstatic\.com/[^)]+)\)"#)
        let found = pattern.matches(in: css, range: NSRange(css.startIndex..., in: css)).compactMap { Range($0.range(at: 1), in: css).map { String(css[$0]) } }
        for remote in Set(found) {
            guard let ru = URL(string: remote) else { continue }
            let (fd, fc) = try await getData(ru)
            guard fc == 200 else { continue }
            let name = UUID().uuidString.prefix(8) + "." + (ru.pathExtension.isEmpty ? "woff2" : ru.pathExtension)
            try fd.write(to: dir.appendingPathComponent(String(name)), options: .atomic)
            css = css.replacingOccurrences(of: remote, with: "/userfonts/" + name)
        }
        return UserFont(family: family, css: css)
    }
}

// MARK: - search in the novel's saved chapters

struct SearchHit: Identifiable {
    let id = UUID()
    let chapter: Int
    let label: String
    let before: String
    let match: String
    let after: String
    /// which occurrence in that chapter (the reader marks the same one)
    let nth: Int
}

enum TextSearch {
    static func run(novel: Int, query: String, labels: [Int: String], order: [Int: Int]) -> [SearchHit] {
        let q = query.replacingOccurrences(of: "\u{0640}", with: "")
        let rows = DB.shared.query("SELECT t.chapter AS ch, t.paras AS paras FROM texts t JOIN chapters c ON c.id = t.chapter WHERE c.novel = ? AND t.paras LIKE ? ORDER BY c.idx",
                                   [novel, "%" + q + "%"])
        var out: [SearchHit] = []
        for r in rows {
            let ch = r.int("ch")
            guard let d = r.str("paras").data(using: .utf8), let paras = try? JSONSerialization.jsonObject(with: d) as? [String] else { continue }
            var nth = 0
            for p in paras {
                let s = p.replacingOccurrences(of: "\u{0640}", with: "")
                var from = s.startIndex
                while let hit = s.range(of: q, options: [.caseInsensitive], range: from..<s.endIndex) {
                    let b = s.index(hit.lowerBound, offsetBy: -40, limitedBy: s.startIndex) ?? s.startIndex
                    let a = s.index(hit.upperBound, offsetBy: 60, limitedBy: s.endIndex) ?? s.endIndex
                    out.append(SearchHit(chapter: ch, label: labels[ch] ?? "", before: (b > s.startIndex ? "…" : "") + String(s[b..<hit.lowerBound]),
                                         match: String(s[hit]), after: String(s[hit.upperBound..<a]) + (a < s.endIndex ? "…" : ""), nth: nth))
                    nth += 1
                    from = hit.upperBound
                    if out.count >= 300 { return out }
                }
            }
        }
        return out.sorted { (order[$0.chapter] ?? 0, $0.nth) < (order[$1.chapter] ?? 0, $1.nth) }
    }
}
