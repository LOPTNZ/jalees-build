import UIKit
import WebKit

/// One look of the reading page. Every value belongs to its theme: changing the size or spacing in «قبل النوم»
/// leaves «النهار» as it was.
struct ReaderTheme: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var bg: String
    var fg: String
    var font = "thmanyah"
    var latin = "same"
    var size: Double = 22
    var bold = false
    var line: Double = 1.3
    var letter: Double = 0
    var word: Double = 0
    var margin: Double = -10
    /// start (right in Arabic), center, end, justify
    var align = "start"
    /// letter spacing in Arabic stretches the joins with kashida (عــيـن) instead of pulling letters apart
    var kashida = true
    var edited = false

    init(id: String, name: String, bg: String, fg: String) {
        self.id = id; self.name = name; self.bg = bg; self.fg = fg
    }

    /// Reads themes saved by any earlier version: a missing value takes its default.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bg = try c.decode(String.self, forKey: .bg)
        fg = try c.decode(String.self, forKey: .fg)
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? font
        latin = try c.decodeIfPresent(String.self, forKey: .latin) ?? latin
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? bold
        line = try c.decodeIfPresent(Double.self, forKey: .line) ?? line
        letter = try c.decodeIfPresent(Double.self, forKey: .letter) ?? letter
        word = try c.decodeIfPresent(Double.self, forKey: .word) ?? word
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        align = try c.decodeIfPresent(String.self, forKey: .align) ?? align
        kashida = try c.decodeIfPresent(Bool.self, forKey: .kashida) ?? kashida
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? edited
    }

    /// The owner's own Apple Books setup is the starting point: black page, line spacing 1.30, margins -10%.
    static let builtIn: [ReaderTheme] = [
        ReaderTheme(id: "day", name: "النهار", bg: "#000000", fg: "#FFFFFF"),
        ReaderTheme(id: "night", name: "قبل النوم", bg: "#000000", fg: "#8E8E93"),
        ReaderTheme(id: "grey", name: "رمادي", bg: "#1C1C1E", fg: "#E5E5EA"),
        ReaderTheme(id: "warm", name: "دافئ", bg: "#1E1A15", fg: "#E9DFCC"),
        ReaderTheme(id: "paper", name: "ورقي", bg: "#F4ECD8", fg: "#3A2F25"),
        ReaderTheme(id: "light", name: "فاتح", bg: "#FFFFFF", fg: "#111111")
    ]

    static let builtInFonts: [(id: String, name: String)] = [
        ("thmanyah", "ثمانية"), ("thmanyah-sans", "ثمانية سانس"), ("amiri", "أميري"), ("plex", "بلكس"), ("system", "خط النظام")
    ]

    var isDark: Bool { UIColor(hex: bg).luminance < 0.5 }

    static func family(_ id: String) -> (body: String, head: String) {
        switch id {
        case "thmanyah": return ("\"Thmanyah Serif Text\"", "\"Thmanyah Serif Display\"")
        case "thmanyah-sans": return ("\"Thmanyah Sans\"", "\"Thmanyah Sans\"")
        case "amiri": return ("\"Amiri\"", "\"Amiri\"")
        case "plex": return ("\"IBM Plex Sans Arabic\"", "\"IBM Plex Sans Arabic\"")
        case "system": return ("-apple-system", "-apple-system")
        default:
            // a font the owner added (file or Google Fonts): its family name is its id after "u:"
            let n = id.hasPrefix("u:") ? String(id.dropFirst(2)) : id
            return ("\"\(n)\"", "\"\(n)\"")
        }
    }

    /// What reader.js needs (JR.setPrefs).
    var css: [String: Any] {
        let c = UIColor(hex: fg).rgb
        let rgba = { (a: Double) in "rgba(\(c.0),\(c.1),\(c.2),\(a))" }
        let f = ReaderTheme.family(font)
        let l = latin == "same" ? f.body : ReaderTheme.family(latin).body
        return [
            "bg": bg, "fg": fg, "soft": rgba(0.5), "line": rgba(0.16), "tint": rgba(0.06),
            "font": f.body, "head": f.head, "latin": l, "size": size, "weight": bold ? 700 : 400, "lh": line,
            "ls": letter / 100, "ws": word / 100 * 0.6, "side": max(6, 26 + 1.1 * margin),
            "align": align, "kashida": kashida && letter > 0 ? max(1, Int((letter / 5).rounded())) : 0
        ]
    }
}

/// How reading behaves, the same in every theme.
struct ReaderPrefs: Codable, Equatable {
    /// chapter: scroll one chapter at a time · continuous: one endless scroll with a line between chapters · paged: pages
    var mode = "continuous"
    /// how characters' names stand out: tint, underline, bold, glow or off
    var nameStyle = "tint"
    var version = 2
    /// books from EPUB files read as one endless scroll unless changed
    var epubMode = "continuous"
    /// how pages turn in paged mode: slide or fade
    var anim = "slide"
    var comments = true
    var swipeChapters = true
    var hideHeading = false
    /// characters' names lightly marked in the text; a tap shows their card
    var showNames = true
    var showRibbon = false
    var landscapeColumns = 2
    var autoSpeed: Double = 40
    var guideDim: Double = 0.72
    var guideLines = 1
    var ahead = 5
    var advanced = false

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let x = ReaderPrefs()
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? x.mode
        nameStyle = try c.decodeIfPresent(String.self, forKey: .nameStyle) ?? x.nameStyle
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // from version 2 the endless scroll is the default way of reading
        if version < 2 { mode = "continuous"; version = 2 }
        epubMode = try c.decodeIfPresent(String.self, forKey: .epubMode) ?? x.epubMode
        anim = try c.decodeIfPresent(String.self, forKey: .anim) ?? x.anim
        comments = try c.decodeIfPresent(Bool.self, forKey: .comments) ?? x.comments
        swipeChapters = try c.decodeIfPresent(Bool.self, forKey: .swipeChapters) ?? x.swipeChapters
        hideHeading = try c.decodeIfPresent(Bool.self, forKey: .hideHeading) ?? x.hideHeading
        showNames = try c.decodeIfPresent(Bool.self, forKey: .showNames) ?? x.showNames
        showRibbon = try c.decodeIfPresent(Bool.self, forKey: .showRibbon) ?? x.showRibbon
        landscapeColumns = try c.decodeIfPresent(Int.self, forKey: .landscapeColumns) ?? x.landscapeColumns
        autoSpeed = try c.decodeIfPresent(Double.self, forKey: .autoSpeed) ?? x.autoSpeed
        guideDim = try c.decodeIfPresent(Double.self, forKey: .guideDim) ?? x.guideDim
        guideLines = try c.decodeIfPresent(Int.self, forKey: .guideLines) ?? x.guideLines
        ahead = try c.decodeIfPresent(Int.self, forKey: .ahead) ?? x.ahead
        advanced = try c.decodeIfPresent(Bool.self, forKey: .advanced) ?? x.advanced
    }

    var css: [String: Any] {
        ["mode": mode, "anim": anim, "comments": comments, "hideHead": hideHeading, "cols": landscapeColumns]
    }
}

/// A word the owner wants changed everywhere it appears: written loosely (hamza, alef forms, ى/ي, ة/ه and diacritics
/// don't matter), with, if asked, its forms with و، ف، ب، ل، ك، ال and endings, and more words of the same family
/// that each become their own word (إله → رب, آلهة → أرباب, ألوهية → ربوبية), all in one rule.
struct ReplaceRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var from = ""
    var to = ""
    var forms = true
    var on = true
    var more: [Form] = []

    struct Form: Codable, Equatable, Hashable, Identifiable {
        var id = UUID().uuidString
        var from = ""
        /// "" = the rule's own word
        var to = ""
    }

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        forms = try c.decodeIfPresent(Bool.self, forKey: .forms) ?? true
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        more = try c.decodeIfPresent([Form].self, forKey: .more) ?? []
    }

    /// every word this rule changes, with what it becomes
    var pairs: [(String, String)] {
        let base = (from.trimmingCharacters(in: .whitespaces), to)
        return [base] + more.map { ($0.from.trimmingCharacters(in: .whitespaces), $0.to.isEmpty ? to : $0.to) }
    }
}

extension Notification.Name {
    /// a replacement rule changed: the open reader shows its chapter again, in place
    static let replaceRulesChanged = Notification.Name("jalees.replaceRulesChanged")
}

enum Replacer {
    static func rules(_ scope: String) -> [ReplaceRule] {
        (DB.shared.get("replace." + scope)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([ReplaceRule].self, from: $0) } ?? []
    }

    static func save(_ list: [ReplaceRule], _ scope: String) {
        let keep = list.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
        guard keep != rules(scope) else { return }
        if let d = try? JSONEncoder().encode(keep), let s = String(data: d, encoding: .utf8) { DB.shared.set("replace." + scope, keep.isEmpty ? nil : s) }
        cache = [:]
        NotificationCenter.default.post(name: .replaceRulesChanged, object: scope)
    }

    // MARK: matching loosely

    private static let marks = "[\\u064B-\\u065F\\u0670\\u0640]*"

    /// a letter's loose class: the forms a writer (or a translator) uses for the same letter
    private static func cls(_ ch: Character) -> String {
        switch ch {
        case "ا", "أ", "إ", "آ", "ٱ": return "[اأإآٱ]"
        case "ي", "ى", "ئ": return "[يىئ]"
        case "ه", "ة": return "[هة]"
        case "و", "ؤ": return "[وؤ]"
        case "ء": return "[ءأإؤئ]"
        default: return NSRegularExpression.escapedPattern(for: String(ch))
        }
    }

    private static func isMark(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { (0x064B...0x065F).contains($0.value) || $0.value == 0x0670 || $0.value == 0x0640 }
    }

    /// The word as a pattern: each letter in its loose class, diacritics allowed between letters.
    static func loose(_ w: String) -> String {
        w.filter { !isMark($0) }.map { cls($0) + marks }.joined()
    }

    /// The word reduced to compare words by (no diacritics, one alef, one ya, ه for ة).
    static func plain(_ w: String) -> String {
        String(w.filter { !isMark($0) }.map { ch -> Character in
            switch ch {
            case "أ", "إ", "آ", "ٱ": return "ا"
            case "ى", "ئ": return "ي"
            case "ة": return "ه"
            case "ؤ": return "و"
            default: return ch
            }
        })
    }

    private static let edge = "[\\u0600-\\u06FFA-Za-z]"
    private static let prefixes = "((?:[وف])?(?:[بكل])?(?:ال|لل)?)"
    private static let suffixes = "((?:ه|ها|هم|هما|هن|ي|ك|كم|كن|كما|نا|ة|ه|ات|ون|ين|ان|تان|تين|ية|يه|يات|يون|يين)?)"

    private static func regex(_ w: String, forms: Bool) -> NSRegularExpression? {
        let core = loose(w)
        guard !core.isEmpty else { return nil }
        let pattern = forms
            ? "(?<!" + edge + ")" + prefixes + core + suffixes + "(?!" + edge + ")"
            : "(?<!" + edge + ")()" + core + "()(?!" + edge + ")"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static var cache: [Int: [(NSRegularExpression, String)]] = [:]

    private static func compiled(_ novel: Int) -> [(NSRegularExpression, String)] {
        if let c = cache[novel] { return c }
        let list = (rules(String(novel)) + rules("all")).filter(\.on)
        // longer words first, so «الإلهية» is not caught as «الإله» + «ية» by a shorter rule
        let pairs = list.flatMap { r in r.pairs.map { (from: $0.0, to: $0.1, forms: r.forms) } }
            .filter { !$0.from.isEmpty }
            .sorted { plain($0.from).count > plain($1.from).count }
        let out: [(NSRegularExpression, String)] = pairs.compactMap { p in
            guard let re = regex(p.from, forms: p.forms) else { return nil }
            return (re, "$1" + NSRegularExpression.escapedTemplate(for: p.to) + "$2")
        }
        cache[novel] = out
        return out
    }

    /// The novel's rules first, then the ones for every novel.
    static func apply(_ paras: [String], novel: Int) -> [String] {
        let res = compiled(novel)
        guard !res.isEmpty else { return paras }
        return paras.map { p in
            var s = p
            for (re, t) in res { s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t) }
            return s
        }
    }

    // MARK: the word's family in the novel

    /// Words in the novel's saved chapters that look like the same family as `word` (its letters in order, with a
    /// few more), not already caught by its endings and و/ال forms: «اله» finds الهه، آلهة، ألوهية. With how often
    /// each appears, most first. The owner picks which belong.
    static func family(of word: String, novel: Int, skip: Set<String>) async -> [(word: String, count: Int)] {
        let base = plain(word.trimmingCharacters(in: .whitespaces))
        guard base.count >= 2 else { return [] }
        let rows = DB.shared.query("SELECT t.paras FROM texts t JOIN chapters c ON c.id = t.chapter WHERE c.novel = ? ORDER BY c.idx DESC LIMIT 400", [novel])
        let texts = rows.map { $0.str("paras") }
        let skipPlain = Set(skip.map(plain))
        return await Task.detached(priority: .userInitiated) { () -> [(word: String, count: Int)] in
            var counts: [String: Int] = [:]
            var shown: [String: String] = [:]
            let covered = regex(word, forms: true)
            for t in texts {
                for raw in t.split(whereSeparator: { !$0.isLetter && !isMark($0) }) {
                    let w = String(raw)
                    let p = plain(w)
                    guard p.count >= base.count, p.count <= base.count + 6, p != base else { continue }
                    if let re = covered, re.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)) != nil { continue }
                    let stem = strip(p)
                    guard stem != base, !skipPlain.contains(stem), inOrder(base, in: stem) else { continue }
                    counts[stem, default: 0] += 1
                    if shown[stem] == nil { shown[stem] = w.filter { !isMark($0) } }
                }
            }
            return counts.sorted { $0.value > $1.value }.prefix(30).map { (shown[$0.key] ?? $0.key, $0.value) }
        }.value
    }

    /// without و/ف, ب/ك/ل and ال at the front (so «والآلهة» and «آلهة» are one family member)
    private static func strip(_ w: String) -> String {
        var s = Substring(w)
        if s.count > 3, s.first == "و" || s.first == "ف" { s = s.dropFirst() }
        if s.count > 3, s.first == "ب" || s.first == "ك" || s.first == "ل" { s = s.dropFirst() }
        if s.count > 4, s.hasPrefix("ال") { s = s.dropFirst(2) } else if s.count > 4, s.hasPrefix("لل") { s = s.dropFirst(2) }
        return String(s)
    }

    /// the base's letters appear in order in the word, with at most two others between its first and last
    private static func inOrder(_ base: String, in w: String) -> Bool {
        let b = Array(base), x = Array(w)
        var i = 0, first = -1, last = -1
        for (j, ch) in x.enumerated() where i < b.count && ch == b[i] {
            if first < 0 { first = j }
            last = j
            i += 1
        }
        guard i == b.count else { return false }
        return (last - first + 1) - b.count <= 2
    }
}

/// A font the owner added: from a file, or by name from Google Fonts.
struct UserFont: Codable, Identifiable, Equatable {
    var id: String { "u:" + family }
    var family: String
    /// the @font-face rules, with addresses inside the app
    var css: String
}

/// The themes, which one is on, the reading behaviour and the owner's fonts. Saved in the database; every change is
/// published so the open page follows at once.
@MainActor
final class ReaderSettings: ObservableObject {
    static let shared = ReaderSettings()

    @Published private(set) var themes: [ReaderTheme]
    @Published private(set) var currentID: String
    @Published var prefs: ReaderPrefs { didSet { savePrefs() } }
    @Published private(set) var fonts: [UserFont]

    var current: ReaderTheme { themes.first { $0.id == currentID } ?? themes[0] }
    /// kept for older call sites: chapters prepared ahead
    var ahead: Int {
        get { prefs.ahead }
        set { prefs.ahead = newValue }
    }

    var allFonts: [(id: String, name: String)] { ReaderTheme.builtInFonts + fonts.map { ($0.id, $0.family) } }

    private init() {
        var list = ReaderTheme.builtIn
        if let s = DB.shared.get("reader.themes"), let d = s.data(using: .utf8), let saved = try? JSONDecoder().decode([ReaderTheme].self, from: d) {
            list = list.map { base in saved.first { $0.id == base.id } ?? base }
        }
        themes = list
        currentID = DB.shared.get("reader.theme") ?? "day"
        var p = ReaderPrefs()
        if let s = DB.shared.get("reader.prefs"), let d = s.data(using: .utf8), let saved = try? JSONDecoder().decode(ReaderPrefs.self, from: d) { p = saved }
        if let a = Int(DB.shared.get("reader.ahead") ?? "") { p.ahead = a }
        prefs = p
        fonts = (DB.shared.get("reader.fonts")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([UserFont].self, from: $0) } ?? []
    }

    private func save() {
        if let d = try? JSONEncoder().encode(themes), let s = String(data: d, encoding: .utf8) { DB.shared.set("reader.themes", s) }
        DB.shared.set("reader.theme", currentID)
    }

    private func savePrefs() {
        if let d = try? JSONEncoder().encode(prefs), let s = String(data: d, encoding: .utf8) { DB.shared.set("reader.prefs", s) }
    }

    func select(_ id: String) {
        guard themes.contains(where: { $0.id == id }) else { return }
        currentID = id
        save()
    }

    /// Changes the theme that is on.
    func edit(_ change: (inout ReaderTheme) -> Void) {
        guard let i = themes.firstIndex(where: { $0.id == currentID }) else { return }
        var t = themes[i]
        change(&t)
        t.size = min(48, max(12, t.size))
        t.edited = true
        guard t != themes[i] else { return }
        themes[i] = t
        save()
    }

    func resetCurrent() {
        guard let i = themes.firstIndex(where: { $0.id == currentID }), let base = ReaderTheme.builtIn.first(where: { $0.id == currentID }) else { return }
        themes[i] = base
        save()
    }

    func addFont(_ f: UserFont) {
        fonts.removeAll { $0.family == f.family }
        fonts.append(f)
        if let d = try? JSONEncoder().encode(fonts), let s = String(data: d, encoding: .utf8) { DB.shared.set("reader.fonts", s) }
    }

    func removeFont(_ f: UserFont) {
        fonts.removeAll { $0.family == f.family }
        if let d = try? JSONEncoder().encode(fonts), let s = String(data: d, encoding: .utf8) { DB.shared.set("reader.fonts", s) }
        for i in themes.indices where themes[i].font == f.id || themes[i].latin == f.id {
            if themes[i].font == f.id { themes[i].font = "thmanyah" }
            if themes[i].latin == f.id { themes[i].latin = "same" }
        }
        save()
    }

    /// The @font-face rules of every added font, for the page.
    var fontCSS: String { fonts.map(\.css).joined(separator: "\n") }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var rgb: (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var luminance: CGFloat {
        let c = rgb
        return (0.299 * CGFloat(c.0) + 0.587 * CGFloat(c.1) + 0.114 * CGFloat(c.2)) / 255
    }
}

extension WKWebView {
    /// Runs a function body in the page with named arguments. `done` gets the returned value, or nil when the call
    /// failed (the failure and its line are logged). The body must return something.
    func jalees(_ body: String, _ args: [String: Any] = [:], done: ((Any?) -> Void)? = nil) {
        callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
            switch result {
            case .success(let v): done?(v)
            case .failure(let e):
                let ns = e as NSError
                let msg = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
                let line = ns.userInfo["WKJavaScriptExceptionLineNumber"].map { "\($0)" } ?? "?"
                NSLog("jalees js: %@ (line %@) in: %@", msg, line, String(body.prefix(80)))
                done?(nil)
            }
        }
    }
}
