import Foundation

// The library in the same shape the web app kept it (docs/plan/swift/inventory-1-library.md, section 1).
// Each model holds its JSON object and reads and writes its fields through it, so fields this version does not know
// are kept as they are.

/// A model backed by a JSON object.
protocol JSONBacked {
    var raw: JSONObject { get set }
    init(_ raw: JSONObject)
}

extension JSONBacked {
    var jsonID: String { raw.str("id") }
}

// MARK: - the whole library

struct AppState {
    var books: [Book]
    var sessions: [Session]
    var settings: Settings
    /// everything else, as stored: v, demo, goals, shelf, timer, lastBook, ach, achInit, imgMig, …
    var rest: JSONObject

    init(_ o: JSONObject) {
        books = o.objs("books").map(Book.init)
        sessions = o.objs("sessions").map(Session.init)
        settings = Settings(o.obj("set"))
        var r = o
        for k in ["books", "sessions", "set"] { r[k] = nil }
        rest = r
    }

    var json: JSONObject {
        var o = rest
        o.set("books", objects: books.map(\.raw))
        o.set("sessions", objects: sessions.map(\.raw))
        o["set"] = .object(settings.raw)
        return o
    }

    var goals: Goals { get { Goals(rest.obj("goals")) } set { rest["goals"] = .object(newValue.raw) } }
    var lastBook: String? { get { rest.optStr("lastBook") } set { rest.set("lastBook", optional: newValue) } }
    var demo: Bool { get { rest.bool("demo") } set { rest.set("demo", newValue) } }
    var timer: JSONObject? { get { rest["timer"]?.object } set { rest["timer"] = newValue.map { .object($0) } ?? .null } }
    var shelf: JSONObject? { get { rest["shelf"]?.object } set { rest["shelf"] = newValue.map { .object($0) } ?? .null } }
    var ach: JSONObject { get { rest.obj("ach") } set { rest["ach"] = .object(newValue) } }

    func book(_ id: String) -> Book? { books.first { $0.id == id } }
    func index(of id: String) -> Int? { books.firstIndex { $0.id == id } }
}

struct Goals: JSONBacked {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }
    var daily: Int { get { raw.int("daily", 30) } set { raw.set("daily", newValue) } }
    var year: Int { get { raw.int("year", 12) } set { raw.set("year", newValue) } }
}

// MARK: - a book

enum BookStatus: String, CaseIterable {
    case want, reading, done, dnf
    var label: String { ["want": "أريد قراءته", "reading": "أقرأه الآن", "done": "أنهيته", "dnf": "توقفت عنه"][rawValue] ?? "" }
}

enum BookFormat: String, CaseIterable {
    case physical, ebook, audio, web
    var label: String { ["physical": "ملموس", "ebook": "إلكتروني", "audio": "صوتي", "web": "رواية ويب"][rawValue] ?? "" }
}

struct Book: JSONBacked, Identifiable {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }
    var id: String { raw.str("id") }

    var title: String { get { raw.str("title") } set { raw.set("title", newValue) } }
    var author: String { get { raw.str("author") } set { raw.set("author", newValue) } }
    var lang: String { get { raw.str("lang", "ar") } set { raw.set("lang", newValue) } }
    var translated: Bool { get { raw.bool("translated") } set { raw.set("translated", newValue) } }
    var origLang: String { get { raw.str("origLang", "en") } set { raw.set("origLang", newValue) } }
    var translator: String { get { raw.str("translator") } set { raw.set("translator", newValue) } }
    var narrator: String { get { raw.str("narrator") } set { raw.set("narrator", newValue) } }
    /// "volume" counts pages, "chapters" counts chapters
    var structure: String { get { raw.str("structure", "volume") } set { raw.set("structure", newValue) } }
    var format: BookFormat { get { BookFormat(rawValue: raw.str("format", "physical")) ?? .physical } set { raw.set("format", newValue.rawValue) } }
    /// audio books: by "time" or by "chapters"
    var audioBy: String { get { raw.str("audioBy", "time") } set { raw.set("audioBy", newValue) } }
    var speed: Double { get { raw.num("speed", 1) } set { raw.set("speed", newValue) } }
    var series: Bool { get { raw.bool("series") } set { raw.set("series", newValue) } }
    var volumes: [Volume] { get { raw.objs("volumes").map(Volume.init) } set { raw.set("volumes", objects: newValue.map(\.raw)) } }
    var ongoing: Bool { get { raw.bool("ongoing") } set { raw.set("ongoing", newValue) } }
    /// index of the current volume
    var vi: Int { get { raw.int("vi") } set { raw.set("vi", newValue) } }
    /// position inside the current volume (pages, chapters or minutes)
    var pos: Double { get { raw.num("pos") } set { raw.set("pos", newValue) } }
    var status: BookStatus { get { BookStatus(rawValue: raw.str("status", "want")) ?? .want } set { raw.set("status", newValue.rawValue) } }
    var genres: [String] { get { raw.strs("genres") } set { raw.set("genres", newValue) } }
    var cols: [String] { get { raw.strs("cols") } set { raw.set("cols", newValue) } }
    var cover: String? { get { raw.optStr("cover").flatMap { $0.isEmpty ? nil : $0 } } set { raw.set("cover", optional: newValue) } }
    var coverRatio: Double? { get { raw.optNum("coverRatio") } set { raw.set("coverRatio", optional: newValue) } }
    var spine: String? { get { raw.optStr("spine") } set { raw.set("spine", optional: newValue) } }
    var spineRatio: Double? { get { raw.optNum("spineRatio") } set { raw.set("spineRatio", optional: newValue) } }
    /// average colour of the cover as [h, s, l]
    var color: [Double]? {
        get { raw["color"]?.array?.compactMap(\.double).count == 3 ? raw["color"]?.array?.compactMap(\.double) : nil }
        set { raw["color"] = newValue.map { .array($0.map { .number($0) }) } ?? .null }
    }
    var hue: Double { get { raw.num("hue", 160) } set { raw.set("hue", newValue) } }
    var dims: JSONObject? { get { raw["dims"]?.object } set { raw["dims"] = newValue.map { .object($0) } ?? .null } }
    var start: Double? { get { raw.optNum("start") } set { raw.set("start", optional: newValue) } }
    var finish: Double? { get { raw.optNum("finish") } set { raw.set("finish", optional: newValue) } }
    var rating: Double { get { raw.num("rating") } set { raw.set("rating", newValue) } }
    var review: String { get { raw.str("review") } set { raw.set("review", newValue) } }
    var moods: [String] { get { raw.strs("moods") } set { raw.set("moods", newValue) } }
    var pace: String { get { raw.str("pace") } set { raw.set("pace", newValue) } }
    var volReviews: JSONObject { get { raw.obj("volReviews") } set { raw["volReviews"] = .object(newValue) } }
    var readNo: Int { get { raw.int("readNo", 1) } set { raw.set("readNo", newValue) } }
    var history: [JSONObject] { get { raw.objs("history") } set { raw.set("history", objects: newValue) } }
    /// target finish date, yyyy-mm-dd
    var target: String { get { raw.str("target") } set { raw.set("target", newValue) } }
    var platform: String { get { raw.str("platform") } set { raw.set("platform", newValue) } }
    var link: String { get { raw.str("link") } set { raw.set("link", newValue) } }
    var isbn: String { get { raw.str("isbn") } set { raw.set("isbn", newValue) } }
    var purchase: JSONObject { get { raw.obj("purchase") } set { raw["purchase"] = .object(newValue) } }
    var loan: JSONObject { get { raw.obj("loan") } set { raw["loan"] = .object(newValue) } }
    var quotes: [NoteItem] { get { raw.objs("quotes").map(NoteItem.init) } set { raw.set("quotes", objects: newValue.map(\.raw)) } }
    var thoughts: [NoteItem] { get { raw.objs("thoughts").map(NoteItem.init) } set { raw.set("thoughts", objects: newValue.map(\.raw)) } }
    var words: [NoteItem] { get { raw.objs("words").map(NoteItem.init) } set { raw.set("words", objects: newValue.map(\.raw)) } }
    var chars: [BookCharacter] { get { raw.objs("chars").map(BookCharacter.init) } set { raw.set("chars", objects: newValue.map(\.raw)) } }
    var added: Double { get { raw.num("added") } set { raw.set("added", newValue) } }
    var opened: Double { get { raw.num("opened") } set { raw.set("opened", newValue) } }

    // web novels and EPUB books
    var novel: NovelLink? { get { raw["novel"]?.object.map(NovelLink.init).flatMap { $0.novelID > 0 ? $0 : nil } } set { raw["novel"] = newValue.map { .object($0.raw) } ?? .null } }
    var isNovel: Bool { novel != nil }
    var marks: [JSONObject] { get { raw.objs("marks") } set { raw.set("marks", objects: newValue) } }
    var bmarks: [JSONObject] { get { raw.objs("bmarks") } set { raw.set("bmarks", objects: newValue) } }

    func items(_ k: NoteKind) -> [NoteItem] {
        k == .char ? chars.map { NoteItem($0.raw) } : raw.objs(k.listKey).map(NoteItem.init)
    }
}

/// What ties a library book to a novel in the novels database.
struct NovelLink: JSONBacked {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }
    var novelID: Int { raw.int("id") }
    var site: String { get { raw.str("site") } set { raw.set("site", newValue) } }
    var total: Int { get { raw.int("total") } set { raw.set("total", newValue) } }
    var read: Int { get { raw.int("read") } set { raw.set("read", newValue) } }
    var unread: Int { get { raw.int("unread") } set { raw.set("unread", newValue) } }
    var cur: Int { get { raw.int("cur", -1) } set { raw.set("cur", newValue) } }
    var curLabel: String { get { raw.str("curLabel") } set { raw.set("curLabel", newValue) } }
    var ongoing: Bool { get { raw.bool("ongoing") } set { raw.set("ongoing", newValue) } }
    var isEpub: Bool { site == "epub" }
}

struct Volume: JSONBacked, Identifiable {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }
    var id: String { raw.str("id") }
    var title: String { get { raw.str("title") } set { raw.set("title", newValue) } }
    /// in the book's unit; nil when unknown
    var total: Double? { get { raw.optNum("total").flatMap { $0 > 0 ? $0 : nil } } set { raw.set("total", optional: newValue) } }
    static func blank() -> Volume { Volume(["id": .string(uid()), "title": .string(""), "total": .null]) }
}

// MARK: - reading sessions

struct Session: JSONBacked, Identifiable {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }
    var id: String { raw.str("id") }
    var bookId: String { get { raw.str("bookId") } set { raw.set("bookId", newValue) } }
    var start: Double { get { raw.num("start") } set { raw.set("start", newValue) } }
    var minutes: Double { get { raw.num("minutes") } set { raw.set("minutes", newValue) } }
    var units: Double { get { raw.num("units") } set { raw.set("units", newValue) } }
    /// "page", "chapter" or "min"
    var unit: String { get { raw.str("unit", "page") } set { raw.set("unit", newValue) } }
    var vi: Int { get { raw.int("vi") } set { raw.set("vi", newValue) } }
    var read: Int { get { raw.int("read", 1) } set { raw.set("read", newValue) } }
}

// MARK: - the notebook

enum NoteKind: String, CaseIterable {
    case quote, thought, word, char
    var listKey: String { ["quote": "quotes", "thought": "thoughts", "word": "words", "char": "chars"][rawValue]! }
    var name: String { ["quote": "اقتباس", "thought": "خاطرة", "word": "كلمة", "char": "شخصية"][rawValue]! }
}

/// A quote, thought or word (each kind uses its own fields; all are kept).
struct NoteItem: JSONBacked, Identifiable {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }
    var id: String { raw.str("id") }
    var at: Double { get { raw.num("at") } set { raw.set("at", newValue) } }
    var text: String { get { raw.str("text") } set { raw.set("text", newValue) } }
    var word: String { get { raw.str("word") } set { raw.set("word", newValue) } }
    var meaning: String { get { raw.str("meaning") } set { raw.set("meaning", newValue) } }
    var passage: String { get { raw.str("passage") } set { raw.set("passage", newValue) } }
    var loc: Double? { get { raw.optNum("loc") } set { raw.set("loc", optional: newValue) } }
    var vol: Int { get { raw.int("vol") } set { raw.set("vol", newValue) } }
    var read: Int { get { raw.int("read", 1) } set { raw.set("read", newValue) } }
    var img: String? { get { raw.optStr("img") } set { raw.set("img", optional: newValue) } }
    var fav: Bool { get { raw.bool("fav") } set { raw.set("fav", newValue) } }
    /// where it was taken in a web novel or EPUB: {ch, p, s, label}
    var nv: JSONObject? { raw["nv"]?.object }
}

struct BookCharacter: JSONBacked, Identifiable {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }
    var id: String { raw.str("id") }
    var name: String { get { raw.str("name") } set { raw.set("name", newValue) } }
    var alias: String { get { raw.str("alias") } set { raw.set("alias", newValue) } }
    /// "main" or "secondary"
    var role: String { get { raw.str("role") } set { raw.set("role", newValue) } }
    var desc: String { get { raw.str("desc") } set { raw.set("desc", newValue) } }
    var photo: String? { get { raw.optStr("photo") } set { raw.set("photo", optional: newValue) } }
    /// the chapter (or page) where it is first named
    var first: Double? { get { raw.optNum("first") } set { raw.set("first", optional: newValue) } }
    var firstVol: Int { get { raw.int("firstVol") } set { raw.set("firstVol", newValue) } }
    var rel: [JSONObject] { get { raw.objs("rel") } set { raw.set("rel", objects: newValue) } }
    var custom: [JSONObject] { get { raw.objs("custom") } set { raw.set("custom", objects: newValue) } }
    var at: Double { get { raw.num("at") } set { raw.set("at", newValue) } }
}

// MARK: - settings

struct Settings: JSONBacked {
    var raw: JSONObject
    init(_ raw: JSONObject) { self.raw = raw }

    /// "carousel", "shelf" or "grid"
    var view: String { get { raw.str("view", "carousel") } set { raw.set("view", newValue) } }
    /// carousel style: "stack" or "flow"
    var carStyle: String { get { raw.str("carStyle", "stack") } set { raw.set("carStyle", newValue) } }
    var sort: String { get { raw.str("sort", "lastRead") } set { raw.set("sort", newValue) } }
    var dir: String { get { raw.str("dir", "desc") } set { raw.set("dir", newValue) } }
    var filter: JSONObject { get { raw.obj("f") } set { raw["f"] = .object(newValue) } }
    var show: JSONObject { get { raw.obj("show") } set { raw["show"] = .object(newValue) } }
    var cols: Int { get { raw.int("cols", 3) } set { raw.set("cols", newValue) } }
    var shelfTheme: String { get { raw.str("shelfTheme", "walnut") } set { raw.set("shelfTheme", newValue) } }
    var lights: Bool { get { raw.bool("lights") } set { raw.set("lights", newValue) } }
    var spineUp: Bool { get { raw.bool("spineUp") } set { raw.set("spineUp", newValue) } }
    /// "system", "light" or "dark"
    var theme: String { get { raw.str("theme", "system") } set { raw.set("theme", newValue) } }
    /// teal, indigo, plum, amber
    var accent: String { get { raw.str("accent", "teal") } set { raw.set("accent", newValue) } }
    /// text size: s, m, l
    var fs: String { get { raw.str("fs", "m") } set { raw.set("fs", newValue) } }
    var markLabels: [String: String] {
        get {
            let o = raw.obj("markLabels")
            if o.isEmpty { return ["yellow": "", "green": "", "blue": "تلميح", "pink": "مضحك", "purple": "معلومة", "orange": "", "red": "", "gray": ""] }
            return o.compactMapValues(\.string)
        }
        set { raw["markLabels"] = .object(newValue.mapValues { .string($0) }) }
    }

    /// the web app's defaults (defSettings), under whatever is stored
    static func defaults() -> JSONObject {
        [
            "view": .string("carousel"), "carStyle": .string("stack"), "sort": .string("lastRead"), "dir": .string("desc"),
            "f": .object(["status": .string("all"), "hideDone": .bool(false), "format": .string("all"), "genre": .string(""), "series": .string("all"), "col": .string("")]),
            "show": .object(["prog": .bool(false), "stars": .bool(false), "badge": .bool(false), "shelfBadge": .bool(true)]),
            "cols": .number(3), "dimMode": .string("handles"), "shelfTheme": .string("walnut"), "lights": .bool(false), "spineUp": .bool(false),
            "review": .string("srs"), "spoilers": .bool(true), "sessCover": .bool(false), "wake": .bool(true), "sound": .string("rain"),
            "remind": .object(["on": .bool(false), "time": .string("21:00")]),
            "theme": .string("system"), "accent": .string("teal"), "fs": .string("m"), "gbKey": .string("")
        ]
    }
}

/// The named highlight colours: the owner gives each a meaning (معلومة، مضحك، تلميح…).
enum MarkColor: String, CaseIterable {
    case yellow, green, blue, pink, purple, orange, red, gray
    var hex: String { ["yellow": "#f5c84c", "green": "#6fcf7c", "blue": "#5aa9f0", "pink": "#f07fb4", "purple": "#a98bf0", "orange": "#f2994a", "red": "#eb5757", "gray": "#a7a7a7"][rawValue]! }
    var plain: String { ["yellow": "أصفر", "green": "أخضر", "blue": "أزرق", "pink": "وردي", "purple": "بنفسجي", "orange": "برتقالي", "red": "أحمر", "gray": "رمادي"][rawValue]! }
}
