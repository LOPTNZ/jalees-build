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

/// A word the owner wants changed everywhere it appears (and, if asked, its forms with و، ف، ب، ل، ك، ال and endings).
struct ReplaceRule: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var from = ""
    var to = ""
    var forms = true
}

enum Replacer {
    static func rules(_ scope: String) -> [ReplaceRule] {
        (DB.shared.get("replace." + scope)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([ReplaceRule].self, from: $0) } ?? []
    }

    static func save(_ list: [ReplaceRule], _ scope: String) {
        let keep = list.filter { !$0.from.trimmingCharacters(in: .whitespaces).isEmpty }
        if let d = try? JSONEncoder().encode(keep), let s = String(data: d, encoding: .utf8) { DB.shared.set("replace." + scope, keep.isEmpty ? nil : s) }
    }

    /// The novel's rules first, then the ones for every novel.
    static func apply(_ paras: [String], novel: Int) -> [String] {
        let list = rules(String(novel)) + rules("all")
        guard !list.isEmpty else { return paras }
        let res: [(NSRegularExpression, String)] = list.compactMap { r in
            let w = NSRegularExpression.escapedPattern(for: r.from.trimmingCharacters(in: .whitespaces))
            let edge = "[\\u0600-\\u06FFA-Za-z]"
            let pattern = r.forms
                ? "(?<!" + edge + ")((?:و|ف|ب|ك|ل)?(?:ال|لل)?)" + w + "((?:ه|ها|هم|هما|هن|ي|ك|كم|كن|نا|ة|ات|ون|ين|ان|تان|تين)?)(?!" + edge + ")"
                : "(?<!" + edge + ")()" + w + "()(?!" + edge + ")"
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (re, "$1" + NSRegularExpression.escapedTemplate(for: r.to) + "$2")
        }
        return paras.map { p in
            var s = p
            for (re, t) in res { s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t) }
            return s
        }
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
