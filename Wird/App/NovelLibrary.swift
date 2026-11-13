import Foundation
import UIKit

/// What the novel screens and the reader ask of the library. These were the web app's window.wirdNovel* functions;
/// they keep the same names, inputs and results, so the native novel code changed as little as possible.
@MainActor
enum NovelLibrary {
    static var lib: Library { Library.shared }

    /// The reader's calls, by the names the web library had: "wirdNovelMark(b, m)" with ["b": …, "m": …].
    static func call(_ body: String, _ a: [String: Any]) -> Any? {
        let name = String(body.prefix { $0 != "(" })
        let b = (a["b"] as? String) ?? ""
        switch name {
        case "wirdNovelBook": return book(b)
        case "wirdNovelMarks":
            let m = marks(b, chapter: NovelBridge.num(a["ch"]))
            return ["marks": m.marks, "bmarks": m.bmarks]
        case "wirdNovelAllMarks":
            let m = allMarks(b)
            return ["marks": m.marks, "bmarks": m.bmarks]
        case "wirdNovelMark": if let m = a["m"] as? [String: Any] { mark(b, m) }; return 1
        case "wirdNovelMarkDel": markDel(b, (a["id"] as? String) ?? ""); return 1
        case "wirdNovelBmark": if let m = a["m"] as? [String: Any] { bmark(b, m, on: (a["on"] as? Bool) ?? false) }; return 1
        case "wirdNovelBmarkDel": bmarkDel(b, (a["id"] as? String) ?? ""); return 1
        case "wirdNovelItem": return item(b, (a["k"] as? String) ?? "", (a["o"] as? [String: Any]) ?? [:])
        case "wirdNovelCharFirst":
            return charFirst(b, (a["c"] as? String) ?? "", NovelBridge.num(a["n"]), was: a["w"].map { NovelBridge.num($0) }) ? 1 : 0
        case "wirdNovelSession": return session((a["o"] as? [String: Any]) ?? [:]) ? 1 : 0
        case "wirdNovelLabelsSet": labelsSet(((a["o"] as? [String: Any]) ?? [:]).compactMapValues { $0 as? String }); return 1
        case "wirdNovelStatus": status(b, (a["st"] as? String) ?? ""); return 1
        default: return nil
        }
    }

    // MARK: the book of a novel

    /// The library book of a novel the app has just read from its site or from a file (made once, found after that).
    @discardableResult
    static func ensureBook(_ r: [String: Any]) -> String {
        let nid = NovelBridge.num(r["id"])
        if let b = lib.state.books.first(where: { $0.novel?.novelID == nid }) {
            Novels.shared.link(nid, book: b.id)
            return b.id
        }
        let ep = (r["site"] as? String) == "epub"
        var o = Library.blankBook()
        let total = NovelBridge.num(r["total"])
        let complete = (r["complete"] as? Bool) ?? false
        o.set("title", (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (ep ? "كتاب" : "رواية"))
        o.set("author", (r["author"] as? String) ?? "")
        o.set("translator", (r["translator"] as? String) ?? "")
        o.set("format", ep ? "ebook" : "web")
        o.set("structure", "chapters")
        o.set("ongoing", !complete)
        o.set("status", "want")
        o.set("platform", ep ? "ملف EPUB" : "موقع روايات ويب")
        o.set("link", ep ? "" : ((r["url"] as? String) ?? ""))
        o.set("lang", "ar")
        o.set("genres", Array(((r["genres"] as? [String]) ?? []).prefix(8)))
        o["novel"] = .object(["id": .number(Double(nid)), "site": .string((r["site"] as? String) ?? ""), "total": .number(Double(total)),
                              "read": .number(0), "unread": .number(Double(total)), "cur": .number(-1), "curLabel": .string(""), "ongoing": .bool(!complete)])
        o["volumes"] = .array([.object(["id": .string(uid()), "title": .string(""), "total": total > 0 ? .number(Double(total)) : .null])])
        o["marks"] = .array([]); o["bmarks"] = .array([])
        let b = Book(Library.fixBook(o))
        lib.change { $0.books.append(b) }
        Novels.shared.link(nid, book: b.id)
        return b.id
    }

    /// A novel found while browsing: its book, and its cover from the site.
    static func adopt(_ r: [String: Any]) async -> String {
        let id = ensureBook(r)
        if let u = r["cover"] as? String, !u.isEmpty, lib.state.book(id)?.cover == nil, let url = URL(string: u),
           let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d) {
            setCover(id, img)
        }
        return id
    }

    /// An EPUB just added: its book, its cover, then its page.
    static func epubAdded(_ r: [String: Any]) {
        if let e = r["error"] as? String { Toaster.show(e); return }
        let id = ensureBook(r)
        if lib.state.book(id)?.cover == nil, let s = r["coverData"] as? String, let comma = s.firstIndex(of: ","),
           let d = Data(base64Encoded: String(s[s.index(after: comma)...])), let img = UIImage(data: d) {
            setCover(id, img)
        }
        Router.shared.openNovel(NovelBridge.num(r["id"]), book: id)
        Toaster.show("انضاف «\(lib.state.book(id)?.title ?? "")»")
    }

    static func setCover(_ id: String, _ img: UIImage) {
        guard let cid = lib.putImage(img) else { return }
        lib.changeBook(id) { b in
            b.cover = cid
            b.coverRatio = img.size.height > 0 ? Double(img.size.width / img.size.height) : nil
            b.color = img.averageHSL()
        }
    }

    /// The novel's counts and place, from the novels database.
    static func sync(_ o: [String: Any]) {
        guard let bid = o["book"] as? String, lib.state.book(bid)?.isNovel == true else { return }
        lib.changeBook(bid) { b in
            guard var n = b.novel else { return }
            if let v = o["total"] { n.total = NovelBridge.num(v) }
            if let v = o["unread"] { n.unread = NovelBridge.num(v) }
            if let v = o["read"] { n.read = NovelBridge.num(v) }
            if let v = o["cur"] { n.cur = NovelBridge.num(v) }
            if let v = o["curLabel"] as? String { n.curLabel = v }
            if let v = o["ongoing"] as? Bool { n.ongoing = v }
            b.novel = n
            var vols = b.volumes
            if !vols.isEmpty { vols[0].total = n.total > 0 ? Double(n.total) : nil; b.volumes = vols }
            b.pos = Double(n.read)
            b.ongoing = n.ongoing
            if (o["opened"] as? Bool) == true {
                if b.status == .want { b.status = .reading }
                if b.status == .reading && b.start == nil { b.start = Millis.now }
                b.opened = Millis.now
            }
        }
        if (o["opened"] as? Bool) == true { lib.change { $0.lastBook = bid } }
    }

    static func status(_ id: String, _ st: String) {
        guard let s = BookStatus(rawValue: st) else { return }
        lib.changeBook(id) { b in
            b.status = s
            if s == .reading && b.start == nil { b.start = Millis.now }
            if s == .done && b.finish == nil { b.finish = Millis.now }
        }
        Achievements.check()
    }

    static func labelsSet(_ o: [String: String]) {
        lib.change { st in
            var l = st.settings.markLabels
            for (k, v) in o where MarkColor(rawValue: k) != nil { l[k] = String(v.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24)) }
            st.settings.markLabels = l
        }
    }

    // MARK: everything the novel's page shows

    static func book(_ id: String) -> [String: Any]? {
        guard let b = lib.state.book(id) else { return nil }
        let ss = lib.state.sessions.filter { $0.bookId == b.id }
        let mins = ss.reduce(0) { $0 + $1.minutes }
        let labels = lib.state.settings.markLabels
        func items(_ k: NoteKind, _ n: Int) -> [[String: Any]] {
            b.items(k).sorted { $0.at > $1.at }.prefix(n).map { x in
                let r = x.raw
                var sub = ""
                switch k {
                case .quote:
                    let sid = r.str("speakerId")
                    sub = (!sid.isEmpty && sid != "__o") ? (b.chars.first { $0.id == sid }?.name ?? "") : r.str("speakerName")
                case .word: sub = r.str("meaning").isEmpty ? r.str("tr") : r.str("meaning")
                case .char: sub = r.str("alias").isEmpty ? r.str("desc") : r.str("alias")
                case .thought: sub = r.str("passage")
                }
                var o: [String: Any] = ["id": x.id, "text": [r.str("text"), r.str("word"), r.str("name")].first { !$0.isEmpty } ?? "", "sub": sub, "at": x.at]
                o["loc"] = r.optNum("loc") ?? NSNull()
                o["nv"] = r["nv"].map { $0.any } ?? NSNull()
                return o
            }
        }
        return [
            "id": b.id, "title": b.title, "author": b.author, "translator": b.translator, "status": b.status.rawValue, "readNo": b.readNo,
            "cover": b.cover ?? "", "hue": b.hslString, "rating": b.rating, "genres": b.genres, "link": b.link,
            "labels": MarkColor.allCases.map { ["c": $0.rawValue, "hex": $0.hex, "name": labels[$0.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? $0.plain, "plain": $0.plain] },
            "chars": b.chars.map { ["id": $0.id, "name": $0.name, "alias": $0.alias, "role": $0.role, "desc": $0.desc, "photo": $0.photo ?? ""] },
            "counts": ["quote": b.quotes.count, "thought": b.thoughts.count, "word": b.words.count, "char": b.chars.count],
            "quotes": items(.quote, 3), "thoughts": items(.thought, 3), "words": items(.word, 4), "charsTop": items(.char, 6),
            "marks": sortedByAt(b.marks).map { JSONValue.object($0).any }, "bmarks": sortedByAt(b.bmarks).map { JSONValue.object($0).any },
            "sessions": ["count": ss.count, "minutes": Int(mins.rounded()),
                         "last": ss.suffix(5).reversed().map { ["start": $0.start, "minutes": $0.minutes, "units": $0.units] }] as [String: Any]
        ]
    }

    private static func sortedByAt(_ l: [JSONObject]) -> [JSONObject] { l.sorted { $0.num("at") > $1.num("at") } }

    // MARK: highlights and bookmarks (kept on the book, so the backup and the notebook see them)

    static func marks(_ id: String, chapter: Int) -> (marks: [[String: Any]], bmarks: [[String: Any]]) {
        guard let b = lib.state.book(id) else { return ([], []) }
        func any(_ l: [JSONObject]) -> [[String: Any]] { l.filter { $0.int("ch") == chapter }.compactMap { JSONValue.object($0).any as? [String: Any] } }
        return (any(b.marks), any(b.bmarks))
    }

    static func allMarks(_ id: String) -> (marks: [[String: Any]], bmarks: [[String: Any]]) {
        guard let b = lib.state.book(id) else { return ([], []) }
        func any(_ l: [JSONObject]) -> [[String: Any]] { sortedByAt(l).compactMap { JSONValue.object($0).any as? [String: Any] } }
        return (any(b.marks), any(b.bmarks))
    }

    static func mark(_ id: String, _ m: [String: Any]) {
        guard var o = JSONValue(any: m).object else { return }
        if o.num("at") == 0 { o.set("at", Millis.now) }
        let mid = o.str("id")
        lib.changeBook(id) { b in
            var l = b.marks
            if let i = l.firstIndex(where: { $0.str("id") == mid }) { l[i] = o } else { l.append(o) }
            b.marks = l
        }
    }

    static func markDel(_ id: String, _ mid: String) {
        lib.changeBook(id) { b in b.marks = b.marks.filter { $0.str("id") != mid } }
    }

    static func bmark(_ id: String, _ bm: [String: Any], on: Bool) {
        guard var o = JSONValue(any: bm).object else { return }
        lib.changeBook(id) { b in
            var l = b.bmarks.filter { !($0.int("ch") == o.int("ch") && $0.int("p") == o.int("p")) }
            if on {
                if o.str("id").isEmpty { o.set("id", uid()) }
                o.set("at", Millis.now)
                l.append(o)
            }
            b.bmarks = l
        }
    }

    static func bmarkDel(_ id: String, _ bid: String) {
        lib.changeBook(id) { b in b.bmarks = b.bmarks.filter { $0.str("id") != bid } }
    }

    // MARK: notebook entries from the reader

    /// The web app's blankItem: a new quote, thought, word or character, placed where the book is.
    static func blankItem(_ k: NoteKind, _ b: Book) -> JSONObject {
        let here: JSONValue = b.isNovel ? hereChapter(b).map { .number($0) } ?? .null : (b.pos > 0 ? .number(b.pos) : .null)
        var base: JSONObject = ["id": .string(uid()), "at": .number(Millis.now), "loc": here, "vol": .number(Double(b.vi)), "read": .number(Double(b.readNo))]
        switch k {
        case .quote: base.merge(["text": .string(""), "speakerId": .string(""), "speakerName": .string(""), "fav": .bool(false)]) { $1 }
        case .thought: base.merge(["text": .string(""), "passage": .string("")]) { $1 }
        case .word: base.merge(["word": .string(""), "lang": .string(b.lang != "ar" ? b.lang : "ar"), "tr": .string(""), "meaning": .string(""), "ex": .string(""), "srs": .null]) { $1 }
        case .char:
            base = ["id": .string(uid()), "at": .number(Millis.now), "name": .string(""), "alias": .string(""), "role": .string(""), "gender": .string(""),
                    "age": .string(""), "desc": .string(""), "importance": .string(""), "death": .string(""), "appearance": .string(""), "traits": .string(""),
                    "flaws": .string(""), "change": .string(""), "challenges": .string(""), "photo": .null, "first": here,
                    "firstVol": .number(Double(b.vi)), "rel": .array([]), "custom": .array([])]
        }
        return base
    }

    /// The chapter a novel's reader is in: its number when the site numbers it.
    static func hereChapter(_ b: Book) -> Double? {
        guard let n = b.novel else { return b.pos > 0 ? b.pos : nil }
        if let d = n.curLabel.range(of: #"\d+"#, options: .regularExpression) { return Double(n.curLabel[d]) }
        return n.cur >= 0 ? Double(n.cur + 1) : nil
    }

    /// Saves an entry the reader made; returns its id (a character already named so returns that one).
    static func item(_ id: String, _ kind: String, _ o: [String: Any]) -> String? {
        guard let k = NoteKind(rawValue: kind), let b = lib.state.book(id) else { return nil }
        var x = blankItem(k, b)
        for (key, v) in o { x[key] = JSONValue(any: v) }
        if k == .char, let name = x.optStr("name"), !name.isEmpty, let dup = b.chars.first(where: { $0.name == name }) { return dup.id }
        lib.changeBook(id) { bb in
            var l = bb.raw.objs(k.listKey)
            l.append(x)
            bb.raw.set(k.listKey, objects: l)
        }
        Achievements.check()
        return x.str("id")
    }

    /// A character's first appearance, found in the text (only if it still holds the value it was given when added).
    static func charFirst(_ id: String, _ cid: String, _ n: Int, was: Int?) -> Bool {
        guard let c = lib.state.book(id)?.chars.first(where: { $0.id == cid }) else { return false }
        if let w = was, let f = c.first, Int(f) != w { return false }
        lib.changeBook(id) { b in
            var l = b.chars
            if let i = l.firstIndex(where: { $0.id == cid }) { l[i].first = Double(n); l[i].firstVol = 0 }
            b.chars = l
        }
        return true
    }

    // MARK: reading sessions from the reader (idle time already taken out)

    @discardableResult
    static func session(_ o: [String: Any]) -> Bool {
        guard let bid = o["book"] as? String, let b = lib.state.book(bid) else { return false }
        let minutes = (o["minutes"] as? Double) ?? Double(NovelBridge.num(o["minutes"]))
        guard minutes >= 0.5 else { return false }
        let start = (o["start"] as? Double) ?? Millis.now
        let s = Session([
            "id": .string(uid()), "bookId": .string(b.id), "start": .number(start), "minutes": .number((minutes * 10).rounded() / 10),
            "units": .number(Double(max(0, NovelBridge.num(o["units"])))), "unit": .string("chapter"), "vi": .number(0),
            "from": .number(Double(NovelBridge.num(o["from"]))), "to": .number(Double(NovelBridge.num(o["to"]))),
            "read": .number(Double(b.readNo)), "novel": .number(1)
        ])
        lib.change { $0.sessions.append(s) }
        Achievements.check()
        WidgetFeed.update()
        return true
    }
}

extension Book {
    /// "h s% l%" for the book's colour (from its cover, else its hue), like the web's bookColor.
    var hslString: String {
        if let c = color { return "\(Int(c[0])) \(Int(c[1]))% \(Int(c[2]))%" }
        return "\(Int(hue)) 38% 32%"
    }
}

extension UIImage {
    /// The average colour as [h, s, l] (s clamped to 18–60, l to 18–38), like the web's rasterize.
    func averageHSL() -> [Double]? {
        guard let cg = cgImage else { return nil }
        let w = 12, h = 12
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(w * h) { r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2]) }
        let n = Double(w * h) * 255
        r /= n; g /= n; b /= n
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        var hh = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case r: hh = (g - b) / d + (g < b ? 6 : 0)
            case g: hh = (b - r) / d + 2
            default: hh = (r - g) / d + 4
            }
            hh /= 6
        }
        return [(hh * 360).rounded(), min(60, max(18, (s * 100).rounded())), min(38, max(18, (l * 100).rounded()))]
    }
}
