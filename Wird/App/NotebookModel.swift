import Foundation
import SwiftUI
import UIKit
import Combine

// دفتري 2.4 (docs/plan/notebook-2.4.md). Everything kept from every book in one index, built once per change of the
// library and away from the screen's thread. Every notebook screen reads it: the tab's home and lists, a book's
// notebook page, and the reader's «دفتر الرواية». The cards under them take plain values and watch nothing.

// MARK: - one thing kept

/// One thing kept from a book, the same wherever it is shown.
struct NBEntry: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case quote, mark, thought, word, char, bmark

        /// the notebook's own kind (quote, thought, word, character); nil for a highlight or a bookmark
        var note: NoteKind? { NoteKind(rawValue: rawValue) }

        var symbol: String {
            switch self {
            case .mark: return "highlighter"
            case .bmark: return "bookmark.fill"
            default: return note?.symbol ?? "circle"
            }
        }

        /// one name for each, as everywhere in the app
        var name: String {
            switch self {
            case .mark: return "تظليل"
            case .bmark: return "وقفة"
            default: return note?.name ?? ""
            }
        }

        var plural: String {
            ["quote": "اقتباسات", "mark": "تظليلات", "thought": "أفكار", "word": "كلمات", "char": "شخصيات", "bmark": "وقفات"][rawValue] ?? ""
        }

        /// «12 اقتباسًا», «3 quotes»
        func count(_ n: Int) -> String {
            if Lang.english {
                let en: [String: (String, String)] = ["quote": ("quote", "quotes"), "mark": ("highlight", "highlights"), "thought": ("thought", "thoughts"),
                                                      "word": ("word", "words"), "char": ("character", "characters"), "bmark": ("bookmark", "bookmarks")]
                let w = en[rawValue] ?? ("", "")
                return "\(n) " + (n == 1 ? w.0 : w.1)
            }
            let forms: [String: [String]] = [
                "quote": ["اقتباس واحد", "اقتباسان", "اقتباسات", "اقتباسًا"], "mark": ["تظليل واحد", "تظليلان", "تظليلات", "تظليلًا"],
                "thought": ["فكرة واحدة", "فكرتان", "أفكار", "فكرة"], "word": ["كلمة واحدة", "كلمتان", "كلمات", "كلمة"],
                "char": ["شخصية واحدة", "شخصيتان", "شخصيات", "شخصية"], "bmark": ["وقفة واحدة", "وقفتان", "وقفات", "وقفة"]
            ]
            return Words.cnt(Double(n), forms[rawValue] ?? ["", "", "", ""])
        }
    }

    let kind: Kind
    let book: String
    let rawID: String
    /// a passage's words, a thought, a word, a character's name
    var text = ""
    /// a quote's speaker, a thought's passage, a word's meaning, a character's alias
    var sub = ""
    /// a word's translation
    var alt = ""
    /// your words on it: a highlight's or a quote's note; a word's sentence; a character's description
    var note = ""
    /// the highlight's colour: a highlight's own, or the one marking an entry taken from the text
    var color: String? = nil
    var underline = false
    var fav = false
    var spoiler = false
    var img: String? = nil
    var at: Double = 0
    /// where it is in a novel or an EPUB: the chapter's id (0: no place in the text), the paragraph, the letter
    var ch = 0
    var p = 0
    var s = 0
    /// the place in words: «الفصل 37: …», «ص 12»
    var place = ""
    /// the chapter's (page's) number, for order where the chapter list is not at hand
    var num: Double? = nil
    var tags: [String] = []
    /// the highlight that is this entry's place (a highlight: its own id)
    var markID: String? = nil
    /// a character's picture and role ("main", "secondary")
    var photo: String? = nil
    var role = ""
    /// a word's review: 0 new, 1 learning, 2 known; and whether it is due
    var stage = 0
    var due = false
    /// everything searchable about it, in the search's own form (Words.norm), the book's title too
    var hay = ""
    /// a second (third…) entry of the book with the same id (data from an old import): shown, with an id of its own
    var dup = 0

    var id: String { book + "/" + kind.rawValue + "/" + rawID + (dup > 0 ? "#\(dup)" : "") }
    /// what reading keeps from the text: quotes, highlights, thoughts
    var isPassage: Bool { kind == .quote || kind == .mark || kind == .thought }
}

/// A book that has a notebook, for the shelf of notebooks.
struct NBBook: Identifiable, Equatable {
    let id: String
    var title = ""
    var counts: [NBEntry.Kind: Int] = [:]
    /// everything kept but bookmarks
    var total = 0
    var last: Double = 0
    var due = 0
    func n(_ k: NBEntry.Kind) -> Int { counts[k] ?? 0 }
}

// MARK: - the index

struct NBIndex {
    /// everything kept, bookmarks aside (a place, not a note), newest first
    var all: [NBEntry] = []
    /// each book's, bookmarks included, newest first
    var byBook: [String: [NBEntry]] = [:]
    /// the books that have a notebook, the one kept from last first
    var books: [NBBook] = []
    var counts: [NBEntry.Kind: Int] = [:]
    /// every tag with how many entries carry it
    var tagCounts: [String: Int] = [:]
    /// the owner's names for the highlight colours
    var labels: [String: String] = [:]

    /// the tags, the most used first
    var tags: [String] {
        tagCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    func n(_ k: NBEntry.Kind) -> Int { counts[k] ?? 0 }

    /// The whole library's notebook. Pure: safe away from the screen's thread.
    static func build(_ st: AppState) -> NBIndex {
        var ix = NBIndex()
        ix.labels = st.settings.markLabels
        let now = Millis.now
        for b in st.books {
            let list = entries(of: b, now: now)
            guard !list.isEmpty else { continue }
            ix.byBook[b.id] = list
            var info = NBBook(id: b.id, title: b.title)
            for e in list {
                info.counts[e.kind, default: 0] += 1
                if e.kind == .bmark { continue }
                info.total += 1
                info.last = max(info.last, e.at)
                if e.kind == .word && e.due { info.due += 1 }
                ix.counts[e.kind, default: 0] += 1
                for t in e.tags { ix.tagCounts[t, default: 0] += 1 }
                ix.all.append(e)
            }
            if info.total > 0 { ix.books.append(info) }
        }
        ix.all.sort { $0.at > $1.at }
        ix.books.sort { $0.last > $1.last }
        return ix
    }

    /// One book's notebook: its plain highlights, quotes, thoughts, words (each with its highlight's colour and
    /// place), characters and bookmarks.
    static func entries(of b: Book, now: Double) -> [NBEntry] {
        var out: [NBEntry] = []
        let marks = b.marks
        let lists: [(NoteKind, [JSONObject])] = [(.quote, b.raw.objs("quotes")), (.thought, b.raw.objs("thoughts")), (.word, b.raw.objs("words"))]
        var ids = Set<String>()
        for (_, l) in lists { for x in l { ids.insert(x.str("id")) } }
        var markOf: [String: JSONObject] = [:]
        for m in marks where !m.str("item").isEmpty { markOf[m.str("item")] = m }
        let chars = b.raw.objs("chars")
        var names: [String: String] = [:]
        for c in chars { names[c.str("id")] = c.str("name") }
        let novel = b.novel != nil
        let title = b.title

        // a highlight that is an entry's place is shown as that entry
        for m in marks {
            let item = m.str("item")
            if !item.isEmpty && ids.contains(item) { continue }
            var e = NBEntry(kind: .mark, book: b.id, rawID: m.str("id"))
            e.text = m.str("text")
            e.note = m.str("note")
            e.color = m.str("color", "yellow")
            e.underline = m.str("style") == "ul"
            e.at = m.num("at")
            e.ch = m.int("ch")
            e.p = m.int("p")
            e.s = m.int("s")
            e.place = m.str("chLabel")
            e.num = number(in: e.place)
            e.tags = m.strs("tags")
            e.markID = e.rawID
            e.hay = Words.norm([e.text, e.note, e.place, e.tags.joined(separator: " "), title].joined(separator: " "))
            out.append(e)
        }
        for (k, l) in lists {
            for r in l {
                let id = r.str("id")
                var e = NBEntry(kind: NBEntry.Kind(rawValue: k.rawValue) ?? .quote, book: b.id, rawID: id)
                let lm = markOf[id]
                switch k {
                case .quote:
                    e.text = r.str("text")
                    let sid = r.str("speakerId")
                    e.sub = sid == "__o" ? r.str("speakerName") : (names[sid] ?? "")
                    e.fav = r.bool("fav")
                    e.img = r.optStr("img").flatMap { $0.isEmpty ? nil : $0 }
                    e.note = [r.str("note"), lm?.str("note") ?? ""].first { !$0.isEmpty } ?? ""
                case .thought:
                    e.text = r.str("text")
                    e.sub = r.str("passage")
                    e.note = lm?.str("note") ?? ""
                default:
                    e.text = r.str("word")
                    e.sub = r.str("meaning")
                    e.alt = r.str("tr")
                    e.note = r.str("ex")
                    let srs = r["srs"]?.object
                    e.due = srs == nil || (srs?.num("due") ?? 0) <= now
                    e.stage = srs == nil ? 0 : ((srs?.num("ivl") ?? 0) >= 21 ? 2 : 1)
                }
                e.spoiler = r.bool("spoiler")
                e.at = r.num("at")
                e.tags = r.strs("tags")
                if let m = lm {
                    e.color = m.str("color", "yellow")
                    e.underline = m.str("style") == "ul"
                    e.markID = m.str("id")
                    e.ch = m.int("ch")
                    e.p = m.int("p")
                    e.s = m.int("s")
                    e.place = m.str("chLabel")
                }
                if e.ch == 0, let nv = r["nv"]?.object, nv.int("ch") != 0 {
                    e.ch = nv.int("ch")
                    e.p = nv.int("p")
                    e.s = nv.int("s")
                    e.place = nv.str("label")
                }
                let loc = r.optNum("loc").flatMap { $0 > 0 ? $0 : nil }
                if e.place.isEmpty { e.place = NoteItems.locLabel(b, NoteItem(r)) }
                e.num = (novel ? number(in: e.place) : nil) ?? loc
                e.hay = Words.norm([e.text, e.sub, e.alt, e.note, e.place, e.tags.joined(separator: " "), title].joined(separator: " "))
                out.append(e)
            }
        }
        for c in chars {
            var e = NBEntry(kind: .char, book: b.id, rawID: c.str("id"))
            e.text = c.str("name")
            e.sub = c.str("alias")
            e.note = c.str("desc")
            e.photo = c.optStr("photo").flatMap { $0.isEmpty ? nil : $0 }
            e.role = c.str("role")
            e.at = c.num("at")
            e.tags = c.strs("tags")
            if let f = c.optNum("first"), f > 0 {
                e.num = f
                e.place = b.unit.time ? Words.hm(f) : (b.unit == .chapter ? "الفصل " + Words.n0(f) : b.unit.abbr + " " + Words.n0(f))
            }
            e.hay = Words.norm([e.text, e.sub, e.note, e.tags.joined(separator: " "), title].joined(separator: " "))
            out.append(e)
        }
        for m in b.bmarks {
            var e = NBEntry(kind: .bmark, book: b.id, rawID: m.str("id"))
            e.at = m.num("at")
            e.ch = m.int("ch")
            e.p = m.int("p")
            e.place = m.str("chLabel")
            e.num = number(in: e.place)
            out.append(e)
        }
        // an entry without an id cannot be opened or deleted safely: it is left out; one whose id is taken gets its own
        var seen: [String: Int] = [:]
        var unique: [NBEntry] = []
        for var e in out where !e.rawID.isEmpty {
            let k = e.kind.rawValue + "/" + e.rawID
            e.dup = seen[k, default: 0]
            seen[k] = e.dup + 1
            unique.append(e)
        }
        return unique.sorted { $0.at > $1.at }
    }

    /// the first number in a place's words («الفصل 37: …» → 37)
    static func number(in s: String) -> Double? {
        guard let r = s.range(of: "[0-9]+", options: .regularExpression) else { return nil }
        return Double(s[r])
    }

    // MARK: today's passages

    /// A few passages to read again today (Readwise's daily review): the same all day, others tomorrow. Favourites,
    /// passages with your words on them, and older ones come up more often. Nothing is written down for it.
    func today(_ n: Int = 6, shuffle: Int = 0) -> [NBEntry] {
        let day = Words.dkey(Millis.now) + "|\(shuffle)"
        let now = Millis.now
        var keyed: [(Double, NBEntry)] = []
        for e in all where e.isPassage && !e.spoiler && (!e.text.isEmpty || e.img != nil) {
            var w = 1.0
            if e.fav { w += 3 }
            if !e.note.isEmpty { w += 1 }
            if now - e.at > 30 * DAY { w += 1 }
            keyed.append((pow(NBIndex.unit(e.id + "|" + day), 1 / w), e))
        }
        return keyed.sorted { $0.0 > $1.0 }.prefix(n).map { $0.1 }
    }

    /// a number in (0, 1) that a text always gives (FNV-1a)
    static func unit(_ s: String) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for c in s.utf8 { h = (h ^ UInt64(c)) &* 0x100000001b3 }
        return (Double(h % 1_000_003) + 1) / 1_000_004
    }

    // MARK: words

    struct WordStats: Equatable {
        var fresh = 0
        var learning = 0
        var known = 0
        var due = 0
        var total: Int { fresh + learning + known }
    }

    func words(_ book: String? = nil) -> WordStats {
        var w = WordStats()
        let list = book.map { byBook[$0] ?? [] } ?? all
        for e in list where e.kind == .word {
            switch e.stage {
            case 0: w.fresh += 1
            case 1: w.learning += 1
            default: w.known += 1
            }
            if e.due { w.due += 1 }
        }
        return w
    }

    // MARK: a book's journal

    /// A book's entries as its journal: by chapter in the book's order and inside a chapter by place; or by day,
    /// newest first.
    static func journal(_ list: [NBEntry], chapters: NBChapters, pages: Bool, byDay: Bool) -> [NBGroup] {
        // each key once (a list's ids must be unique), in the order its first entry comes
        var out: [NBGroup] = []
        var at: [String: Int] = [:]
        func put(_ e: NBEntry, _ key: String, _ title: String, _ ch: Int) {
            if let i = at[key] {
                out[i].rows.append(e)
            } else {
                at[key] = out.count
                out.append(NBGroup(id: key, title: title, ch: ch, rows: [e]))
            }
        }
        if byDay {
            for e in list.sorted(by: { $0.at > $1.at }) {
                put(e, e.at > 0 ? "d" + Words.dkey(e.at) : "d-", e.at > 0 ? Words.date(e.at) : "", 0)
            }
            return out
        }
        struct Placed {
            let e: NBEntry
            let key: String
            let rank: Double
            let title: String
            let ch: Int
        }
        let placed: [Placed] = list.map { e -> Placed in
            if let i = chapters.order[e.ch] {
                return Placed(e: e, key: "c\(e.ch)", rank: Double(i), title: chapters.lines[e.ch] ?? e.place, ch: e.ch)
            }
            if e.ch == 0, let id = chapters.chapter(number: e.num), let i = chapters.order[id] {
                return Placed(e: e, key: "c\(id)", rank: Double(i), title: chapters.lines[id] ?? e.place, ch: id)
            }
            if e.ch != 0 {
                return Placed(e: e, key: "c\(e.ch)", rank: 1e7 + (e.num ?? 0), title: e.place, ch: e.ch)
            }
            if let n = e.num, n.isFinite, n > 0, n < 1e7 {
                if pages { return Placed(e: e, key: "pages", rank: 0, title: "", ch: 0) }
                return Placed(e: e, key: "n\(Int(n))", rank: n, title: "الفصل " + Words.n0(n), ch: 0)
            }
            return Placed(e: e, key: "none", rank: 1e9, title: "بدون مكان في النص", ch: 0)
        }
        let sorted = placed.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            // the same rank, two chapters (ones the novel's list does not hold): kept apart
            if a.key != b.key { return a.key < b.key }
            let na = a.e.num ?? 0, nb = b.e.num ?? 0
            if na != nb { return na < nb }
            if a.e.p != b.e.p { return a.e.p < b.e.p }
            if a.e.s != b.e.s { return a.e.s < b.e.s }
            return a.e.at < b.e.at
        }
        for x in sorted { put(x.e, x.key, x.title, x.ch) }
        return out
    }
}

/// A chapter (or a day) of a book's journal and what was kept in it.
struct NBGroup: Identifiable {
    let id: String
    let title: String
    /// the chapter's id in the novel (0: none), to open it
    let ch: Int
    var rows: [NBEntry]
}

/// A novel's chapters, as the journal needs them: id → place in the novel, id → its line, number → id.
struct NBChapters {
    var order: [Int: Int] = [:]
    var lines: [Int: String] = [:]
    var byNum: [String: Int] = [:]

    init() {}

    init(_ rows: [ChapterRow]) {
        for (i, c) in rows.enumerated() {
            order[c.id] = i
            lines[c.id] = c.line
            if c.numbered, byNum[c.num] == nil { byNum[c.num] = c.id }
        }
    }

    func chapter(number v: Double?) -> Int? {
        guard let v = v, v.isFinite, v >= 1, v < 1e7 else { return nil }
        return byNum[String(Int(v))]
    }
}

/// The open reader, when the notebook is its «دفتر الرواية»: its chapters and what it does with a tap.
struct NBReaderLink {
    let chapters: NBChapters
    let bookmarkedHere: Bool
    let open: (Int, Int) -> Void
    let editNote: ([String: Any]) -> Void
    let editItem: (String, String) -> Void
    let openCharacter: (String) -> Void
    let add: (String) -> Void
    let toNotebook: () -> Void
}

// MARK: - the store every notebook screen watches

@MainActor
final class NotebookStore: ObservableObject {
    static let shared = NotebookStore()

    @Published private(set) var ix: NBIndex
    private var sub: AnyCancellable?
    private var saved: NSObjectProtocol?
    private var work: Task<Void, Never>?
    private var todayMemo: (key: String, list: [NBEntry])?

    private init() {
        // the first one at once, so the first frame has the notebook; after that a moment after each change, off the
        // screen's thread
        ix = NBIndex.build(Library.shared.state)
        sub = Library.shared.$state.dropFirst()
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] st in self?.rebuild(st) }
        saved = NotificationCenter.default.addObserver(forName: .noteSaved, object: nil, queue: .main) { n in
            let book = n.userInfo?["book"] as? String
            let id = n.userInfo?["id"] as? String
            Task { @MainActor in NoteItems.linkPending(book: book, id: id) }
        }
    }

    private func rebuild(_ st: AppState) {
        work?.cancel()
        work = Task { @MainActor [weak self] in
            let next = await Task.detached(priority: .userInitiated) { NBIndex.build(st) }.value
            guard !Task.isCancelled, let self = self else { return }
            self.ix = next
            self.todayMemo = nil
        }
    }

    /// today's passages (the same until the day, the shuffle or the notebook changes)
    func today(shuffle: Int) -> [NBEntry] {
        let key = Words.dkey(Millis.now) + "|\(shuffle)|\(ix.all.count)"
        if let m = todayMemo, m.key == key { return m.list }
        let l = ix.today(6, shuffle: shuffle)
        todayMemo = (key, l)
        return l
    }
}

// MARK: - changes made from the notebook

extension NoteItems {
    /// highlights waiting for the entry made from them in the notebook to be saved: the entry's id → its highlight
    @MainActor static var pending: [String: (book: String, mark: String, kind: String, moveNote: Bool)] = [:]

    /// The entry made from a highlight was saved: the two are one thing now (`mark.kind` + `mark.item`, and the
    /// entry's `mark`), and the highlight's words went into the entry.
    @MainActor static func linkPending(book: String?, id: String?) {
        guard let id = id, let p = pending.removeValue(forKey: id), p.book == book else { return }
        Library.shared.changeBook(p.book) { b in
            var l = b.marks
            guard let i = l.firstIndex(where: { $0.str("id") == p.mark }) else { return }
            l[i].set("kind", p.kind)
            l[i].set("item", id)
            if p.moveNote { l[i].set("note", "") }
            b.marks = l
        }
    }

    @MainActor static func toggleFav(_ bookID: String, _ id: String) {
        Library.shared.changeBook(bookID) { b in
            b.raw.set("quotes", objects: b.raw.objs("quotes").map { q in
                var q = q
                if q.str("id") == id { q.set("fav", !q.bool("fav")) }
                return q
            })
        }
        Haptics.play("sel")
    }

    /// An entry's tags (a highlight's too): the owner's own collections.
    @MainActor static func setTags(_ e: NBEntry, _ tags: [String]) {
        var clean: [String] = []
        for t in tags {
            let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !x.isEmpty && !clean.contains(x) { clean.append(x) }
        }
        let key: String
        switch e.kind {
        case .mark: key = "marks"
        case .bmark: return
        default: key = e.kind.note?.listKey ?? "quotes"
        }
        Library.shared.changeBook(e.book) { b in
            b.raw.set(key, objects: b.raw.objs(key).map { x in
                var x = x
                if x.str("id") == e.rawID { x.set("tags", clean) }
                return x
            })
        }
    }

    /// Several entries at once (the notebook's selection), with one undo for all of them.
    @MainActor static func deleteMany(_ list: [NBEntry]) {
        guard !list.isEmpty else { return }
        var taken: [Removal] = []
        for (bid, group) in Dictionary(grouping: list, by: { $0.book }) {
            var r = Removal(book: bid)
            Library.shared.changeBook(bid) { bb in
                for e in group { take(e.kind, e.rawID, from: &bb, into: &r) }
            }
            taken.append(r)
        }
        Haptics.play("warn")
        let n = Words.cnt(Double(list.count), ["عنصر واحد", "عنصران", "عناصر", "عنصرًا"])
        let undo = taken
        ToastCenter.shared.show("تم حذف \(n)") { NoteItems.restore(undo) }
    }

    /// What a deletion took out of a book, to put back into the book as it is now: an undo never rolls back the rest
    /// of the book (a session saved, the place read, a highlight made in the meantime all stay).
    struct Removal {
        let book: String
        /// the list ("quotes", "marks", "chars"…), the object's place in it, the object
        var objects: [(key: String, index: Int, obj: JSONObject)] = []
        /// relations other characters had to a deleted character: (that character, the relation)
        var rels: [(char: String, rel: JSONObject)] = []
        /// quotes whose speaker was a deleted character: (the quote, the character)
        var speakers: [(quote: String, char: String)] = []
        /// entries a deleted highlight was the place of: (their list, the entry, the highlight)
        var links: [(key: String, item: String, mark: String)] = []
    }

    /// Takes one thing kept out of a book, with what goes with it, and notes all it took: an entry's highlights go with
    /// it (they are one thing); a highlight that was an entry's place leaves the entry unmarked; a character leaves the
    /// others' relations, and its quotes keep its name. Only the first object with the id goes (a second one from an
    /// old import stays); an empty id takes nothing.
    static func take(_ kind: NBEntry.Kind, _ id: String, from bb: inout Book, into r: inout Removal) {
        guard !id.isEmpty else { return }
        func cut(_ key: String) -> JSONObject? {
            var l = bb.raw.objs(key)
            guard let i = l.firstIndex(where: { $0.str("id") == id }) else { return nil }
            let o = l.remove(at: i)
            bb.raw.set(key, objects: l)
            r.objects.append((key: key, index: i, obj: o))
            return o
        }
        switch kind {
        case .mark:
            guard let m = cut("marks") else { return }
            let item = m.str("item")
            if let k = NoteKind(rawValue: m.str("kind")), k != .char, !item.isEmpty {
                var l = bb.raw.objs(k.listKey)
                if let j = l.firstIndex(where: { $0.str("id") == item }), l[j]["mark"] != nil {
                    l[j]["mark"] = nil
                    bb.raw.set(k.listKey, objects: l)
                    r.links.append((key: k.listKey, item: item, mark: id))
                }
            }
        case .bmark:
            _ = cut("bmarks")
        case .char:
            guard let c = cut("chars") else { return }
            let name = c.str("name")
            var chars = bb.raw.objs("chars")
            for j in chars.indices {
                let rel = chars[j].objs("rel")
                let gone = rel.filter { $0.str("to") == id }
                if gone.isEmpty { continue }
                for x in gone { r.rels.append((char: chars[j].str("id"), rel: x)) }
                chars[j].set("rel", objects: rel.filter { $0.str("to") != id })
            }
            bb.raw.set("chars", objects: chars)
            var quotes = bb.raw.objs("quotes")
            for j in quotes.indices where quotes[j].str("speakerId") == id {
                r.speakers.append((quote: quotes[j].str("id"), char: id))
                quotes[j].set("speakerId", "__o")
                quotes[j].set("speakerName", name)
            }
            bb.raw.set("quotes", objects: quotes)
        default:
            guard let k = kind.note, cut(k.listKey) != nil else { return }
            var marks = bb.marks
            var i = 0, gone = 0
            while i < marks.count {
                if marks[i].str("item") == id {
                    // its place in the list before any was taken, so putting them back in order rebuilds it
                    r.objects.append((key: "marks", index: i + gone, obj: marks.remove(at: i)))
                    gone += 1
                } else {
                    i += 1
                }
            }
            bb.marks = marks
        }
    }

    /// Puts back what deletions took, into the books as they are now.
    @MainActor static func restore(_ list: [Removal]) {
        for r in list {
            Library.shared.changeBook(r.book) { bb in put(r, into: &bb) }
        }
    }

    /// One removal put back into its book as it is now (what is there already is not doubled).
    static func put(_ r: Removal, into bb: inout Book) {
        for o in r.objects.sorted(by: { $0.index < $1.index }) {
            var l = bb.raw.objs(o.key)
            let oid = o.obj.str("id")
            if l.contains(where: { $0.str("id") == oid }) { continue }
            l.insert(o.obj, at: min(max(0, o.index), l.count))
            bb.raw.set(o.key, objects: l)
        }
        if !r.rels.isEmpty {
            var chars = bb.raw.objs("chars")
            for x in r.rels {
                guard let j = chars.firstIndex(where: { $0.str("id") == x.char }) else { continue }
                var rel = chars[j].objs("rel")
                if rel.contains(where: { $0.str("to") == x.rel.str("to") }) { continue }
                rel.append(x.rel)
                chars[j].set("rel", objects: rel)
            }
            bb.raw.set("chars", objects: chars)
        }
        if !r.speakers.isEmpty {
            var quotes = bb.raw.objs("quotes")
            for x in r.speakers {
                guard let j = quotes.firstIndex(where: { $0.str("id") == x.quote }), quotes[j].str("speakerId") == "__o" else { continue }
                quotes[j].set("speakerId", x.char)
                quotes[j].set("speakerName", "")
            }
            bb.raw.set("quotes", objects: quotes)
        }
        for x in r.links {
            var l = bb.raw.objs(x.key)
            guard let j = l.firstIndex(where: { $0.str("id") == x.item }), l[j]["mark"] == nil else { continue }
            l[j].set("mark", x.mark)
            bb.raw.set(x.key, objects: l)
        }
    }
}

// MARK: - copying, sharing, exporting

@MainActor
enum NotebookExport {
    /// a highlight colour's name: the owner's, else the colour's own
    static func colorName(_ c: String) -> String {
        let n = (Library.shared.state.settings.markLabels[c] ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (MarkColor(rawValue: c)?.plain.tr ?? c) : n
    }

    /// One entry as text to copy or share.
    static func plain(_ e: NBEntry) -> String {
        let b = Library.shared.state.book(e.book)
        let source = b.map { $0.title + ($0.author.isEmpty ? "" : "، " + $0.author) } ?? ""
        switch e.kind {
        case .quote, .mark:
            var s = "«" + e.text + "»"
            if e.kind == .quote && !e.sub.isEmpty { s += "\n— " + e.sub }
            let foot = [source, e.place.tr].filter { !$0.isEmpty }.joined(separator: " · ")
            if !foot.isEmpty { s += "\n" + foot }
            if !e.note.isEmpty { s += "\n\n" + e.note }
            return s
        case .thought:
            return [e.text, e.sub.isEmpty ? "" : "«" + e.sub + "»", source].filter { !$0.isEmpty }.joined(separator: "\n\n")
        case .word:
            return [e.text, e.alt, e.sub].filter { !$0.isEmpty }.joined(separator: " — ")
        case .char:
            return [e.text, e.note].filter { !$0.isEmpty }.joined(separator: ": ")
        case .bmark:
            return [source, e.place.tr].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    static func text(_ list: [NBEntry]) -> String {
        list.map { plain($0) }.joined(separator: "\n\n———\n\n")
    }

    /// Entries as Markdown: each book, its passages by chapter (quotes as quotes, your notes under them), its words
    /// and its characters.
    static func markdown(_ list: [NBEntry]) -> String {
        let st = Library.shared.state
        var out: [String] = []
        var order: [String] = []
        for e in list where !order.contains(e.book) { order.append(e.book) }
        let byBook = Dictionary(grouping: list, by: { $0.book })
        for bid in order {
            let b = st.book(bid)
            out.append("## " + (b?.title ?? ""))
            if let a = b?.author, !a.isEmpty { out.append("_" + a + "_") }
            out.append("")
            let items = byBook[bid] ?? []
            let passages = items.filter(\.isPassage).sorted { a, c in
                let x = a.num ?? 1e9, y = c.num ?? 1e9
                if x != y { return x < y }
                if a.p != c.p { return a.p < c.p }
                return a.at < c.at
            }
            var lastHead = "\u{1}"
            for e in passages {
                let head = e.ch != 0 ? e.place.tr : ""
                if head != lastHead {
                    lastHead = head
                    if !head.isEmpty { out.append("### " + head); out.append("") }
                }
                if e.kind == .thought {
                    out.append("**" + "فكرة".tr + ":** " + e.text)
                    if !e.sub.isEmpty { out.append("> " + e.sub.replacingOccurrences(of: "\n", with: "\n> ")) }
                } else {
                    out.append("> " + e.text.replacingOccurrences(of: "\n", with: "\n> "))
                    if e.kind == .quote && !e.sub.isEmpty { out.append(">\n> — " + e.sub) }
                    if !e.note.isEmpty { out.append(""); out.append(e.note) }
                }
                let meta = [e.kind.name.tr, e.kind == .mark ? (e.color.map { colorName($0) } ?? "") : "",
                            e.ch == 0 ? e.place.tr : "", Words.date(e.at), e.tags.map { "#" + $0 }.joined(separator: " ")]
                out.append("_" + meta.filter { !$0.isEmpty }.joined(separator: " · ") + "_")
                out.append("")
            }
            let words = items.filter { $0.kind == .word }
            if !words.isEmpty {
                out.append("### " + "الكلمات".tr)
                for w in words {
                    let rest = [w.alt, w.sub].filter { !$0.isEmpty }.joined(separator: "، ")
                    out.append("- **" + w.text + "**" + (rest.isEmpty ? "" : " — " + rest))
                }
                out.append("")
            }
            let chars = items.filter { $0.kind == .char }
            if !chars.isEmpty {
                out.append("### " + "الشخصيات".tr)
                for c in chars {
                    let who = c.sub.isEmpty ? "" : " (" + c.sub + ")"
                    out.append("- **" + c.text + "**" + who + (c.note.isEmpty ? "" : ": " + c.note))
                }
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    static func shareText(_ list: [NBEntry]) { Share.text(text(list)) }

    static func shareMarkdown(_ list: [NBEntry], name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? "jalees-notebook" : safe) + ".md")
        guard (try? markdown(list).data(using: .utf8)?.write(to: url)) != nil else { ToastCenter.shared.show("تعذّر التصدير"); return }
        Share.files([url])
    }

    /// The words as a CSV that Anki imports: the word, its translation, meaning and sentence, the book.
    static func anki(_ book: String?) {
        let rows = Library.shared.state.books.filter { book == nil || $0.id == book }.flatMap { b in b.words.map { (b, $0) } }
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let csv = rows.map { b, w in
            [w.raw.str("word"), [w.raw.str("tr"), w.raw.str("meaning"), w.raw.str("ex").isEmpty ? "" : "«" + w.raw.str("ex") + "»"].filter { !$0.isEmpty }.joined(separator: "<br>"), b.title]
                .map(esc).joined(separator: ",")
        }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jalees-words.csv")
        try? ("\u{FEFF}" + csv).data(using: .utf8)?.write(to: url)
        Share.files([url])
    }
}
