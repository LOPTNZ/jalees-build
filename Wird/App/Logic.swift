import Foundation

// The web app's derived values and words (01-core.js, 02-library.js), the same rules in Swift.

enum Unit: String {
    case page, chapter, min
    var abbr: String { ["page": "ص", "chapter": "ف", "min": ""][rawValue]! }
    var name: String { ["page": "الصفحة", "chapter": "الفصل", "min": "الدقيقة"][rawValue]! }
    var pl: String { ["page": "صفحة", "chapter": "فصل", "min": "دقيقة"][rawValue]! }
    var plu: String { ["page": "الصفحات", "chapter": "الفصول", "min": "الوقت"][rawValue]! }
    var time: Bool { self == .min }
    /// plural forms for cnt: one, two, 3–10, 11+
    var forms: [String] {
        switch self {
        case .page: return ["صفحة واحدة", "صفحتان", "صفحات", "صفحة"]
        case .chapter: return ["فصل واحد", "فصلان", "فصول", "فصلًا"]
        case .min: return ["دقيقة واحدة", "دقيقتان", "دقائق", "دقيقة"]
        }
    }
}

/// The words that change between reading and listening.
struct Verbs {
    let doing, now, start, cont, again, time, sess, act: String
    static let read = Verbs(doing: "تقرأ", now: "تقرأ الآن", start: "ابدأ القراءة", cont: "تابع القراءة", again: "ابدأ قراءة جديدة",
                            time: "وقت القراءة", sess: "جلسة قراءة", act: "القراءة")
    static let listen = Verbs(doing: "تستمع", now: "تستمع الآن", start: "ابدأ الاستماع", cont: "تابع الاستماع", again: "ابدأ استماعًا جديدًا",
                              time: "وقت الاستماع", sess: "جلسة استماع", act: "الاستماع")
}

enum Words {
    static let months = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"]
    static let ordinals = ["الأولى", "الثانية", "الثالثة", "الرابعة", "الخامسة", "السادسة", "السابعة", "الثامنة", "التاسعة", "العاشرة"]
    static let books = ["كتاب واحد", "كتابان", "كتب", "كتابًا"]
    static let days = ["يوم واحد", "يومان", "أيام", "يومًا"]
    static let times = ["مرة واحدة", "مرتين", "مرات", "مرة"]
    static let sessions = ["جلسة واحدة", "جلستان", "جلسات", "جلسة"]
    static let vols = ["مجلد واحد", "مجلدان", "مجلدات", "مجلدًا"]

    static func ord(_ n: Int) -> String { n >= 1 && n <= 10 ? ordinals[n - 1] : "رقم \(n)" }

    /// Arabic counting: 0 → "0 كتاب", 1 → "كتاب واحد", 2 → "كتابان", 3–10 → "3 كتب", 11+ → "11 كتابًا".
    static func cnt(_ n: Double, _ f: [String]) -> String {
        let n = Int(n.rounded())
        if n == 0 { return "0 " + f[3] }
        if n == 1 { return f[0] }
        if n == 2 { return f[1] }
        let m = n % 100
        return "\(n) " + (m >= 3 && m <= 10 ? f[2] : f[3])
    }

    static func fmtMin(_ m: Double) -> String {
        if m > 0 && m < 1 { return "أقل من دقيقة" }
        let m = Int(m.rounded())
        if m < 60 { return "\(m) د" }
        let h = m / 60, r = m % 60
        return r > 0 ? "\(h) س \(r) د" : "\(h) س"
    }

    static func hm(_ m: Double) -> String {
        let m = max(0, Int(m.rounded()))
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    /// "12 نوفمبر" (with the year when asked, or when it is not this year)
    static func date(_ ms: Double?, year: Bool = false) -> String {
        guard let ms = ms, ms > 0 else { return "" }
        let c = Calendar.current.dateComponents([.day, .month, .year], from: Millis.date(ms))
        let thisYear = Calendar.current.component(.year, from: Date())
        return "\(c.day ?? 1) \(months[(c.month ?? 1) - 1])" + (year || c.year != thisYear ? " \(c.year ?? thisYear)" : "")
    }

    static func n0(_ x: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: x.rounded())) ?? String(Int(x.rounded()))
    }

    static func stars(_ r: Double) -> String { String(repeating: "★", count: max(0, min(5, Int(r.rounded())))) }

    /// The web app's search form: lowercase, no marks or tatweel, one form for alef, ya, ta marbuta, hamza seats.
    static func norm(_ s: String) -> String {
        var t = s.lowercased().decomposedStringWithCompatibilityMapping
        t = t.unicodeScalars.filter { !(0x0300...0x036F).contains($0.value) && !(0x064B...0x0670).contains($0.value) && $0.value != 0x065F && $0.value != 0x0640 }
            .map(String.init).joined()
        let map: [Character: Character] = ["أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه", "ؤ": "و", "ئ": "ي"]
        t = String(t.map { map[$0] ?? $0 })
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A local day as yyyy-mm-dd.
    static func dkey(_ ms: Double) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Millis.date(ms))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// yyyy-mm-dd to noon that day.
    static func fromIso(_ s: String) -> Double? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count >= 3 else { return nil }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        return Calendar.current.date(from: c).map(Millis.ms)
    }
}

let DAY: Double = 86_400_000

extension Book {
    var isAudio: Bool { format == .audio }
    var unit: Unit {
        if isAudio { return audioBy == "time" ? .min : .chapter }
        return structure == "volume" ? .page : .chapter
    }
    var verbs: Verbs { isAudio ? .listen : .read }
    var curVolume: Volume? { volumes.isEmpty ? nil : volumes[min(max(vi, 0), volumes.count - 1)] }
    var allKnown: Bool { volumes.allSatisfy { ($0.total ?? 0) > 0 } }
    var sumTotal: Double { volumes.reduce(0) { $0 + ($1.total ?? 0) } }
    var doneUnits: Double {
        var s = 0.0
        for i in 0..<min(vi, volumes.count) { s += volumes[i].total ?? 0 }
        return s + pos
    }
    /// 0…1, nil when a total is unknown
    var pct: Double? {
        if status == .done { return 1 }
        guard allKnown else { return nil }
        let t = sumTotal
        return t > 0 ? min(1, max(0, doneUnits / t)) : nil
    }
    func uv(_ n: Double) -> String { unit.time ? Words.hm(n) : Words.n0(n) }

    var posLabel: String {
        let v = curVolume, tot = v?.total
        let p = uv(pos) + (tot.map { " / " + uv($0) } ?? "")
        let volTitle = "المجلد \(vi + 1)" + ((v?.title.isEmpty ?? true) ? "" : " · " + (v?.title ?? ""))
        if unit.time { return (series ? volTitle + " · " : "") + p }
        if series { return volTitle + " · " + unit.abbr + " " + p }
        return unit.abbr + " " + p + (tot == nil && ongoing ? " · مستمرة" : "")
    }

    var shortPos: String {
        (series ? "م\(vi + 1) · " : "") + uv(pos) + "/" + (curVolume?.total.map { uv($0) } ?? "؟")
    }

    var coverAspect: Double { min(0.9, max(0.5, coverRatio ?? 0.66)) }
}

extension AppState {
    func sessions(of id: String, read: Int? = nil) -> [Session] { sessions.filter { $0.bookId == id && (read == nil || $0.read == read) } }

    func lastTs(_ b: Book) -> Double {
        var t = b.opened
        for s in sessions where s.bookId == b.id && s.start > t { t = s.start }
        return t > 0 ? t : b.added
    }

    func speed(_ list: [Session], _ u: Unit) -> Double? {
        var m = 0.0, p = 0.0
        for s in list where s.unit == u.rawValue { m += s.minutes; p += s.units }
        return m >= 5 && p > 0 ? p / (m / 60) : nil
    }

    func speed(for b: Book) -> Double? { speed(sessions(of: b.id), b.unit) ?? speed(sessions, b.unit) }

    func remainUnits(_ b: Book) -> Double? { b.allKnown ? max(0, b.sumTotal - b.doneUnits) : nil }

    /// minutes left at your speed
    func estRemain(_ b: Book) -> Double? {
        guard let r = remainUnits(b) else { return nil }
        let sp = speed(for: b)
        if b.unit.time { return sp.map { r / $0 * 60 } ?? r / (b.speed > 0 ? b.speed : 1) }
        return sp.map { r / $0 * 60 }
    }

    /// When you would finish at your pace of the last 21 days.
    func estFinishDate(_ b: Book) -> Double? {
        guard let r = remainUnits(b), r > 0, b.status == .reading else { return nil }
        let since = Millis.now - 21 * DAY
        let u = sessions(of: b.id, read: b.readNo).filter { $0.start >= since }.reduce(0) { $0 + $1.units }
        let perDay = u / 21
        guard perDay > 0 else { return nil }
        return Millis.now + (r / perDay).rounded(.up) * DAY
    }

    func minutesByDay() -> [String: Double] {
        var m: [String: Double] = [:]
        for s in sessions { m[Words.dkey(s.start), default: 0] += s.minutes }
        return m
    }

    var todayMin: Double { minutesByDay()[Words.dkey(Millis.now)] ?? 0 }

    func lastBookId() -> String? {
        if let t = timer?.str("bookId"), book(t) != nil { return t }
        if let l = lastBook, book(l) != nil { return l }
        return books.max { lastTs($0) < lastTs($1) }?.id
    }

    /// What the library shows: the filters, the search, the order (libList).
    func libList(query: String) -> [Book] {
        let st = settings, f = st.filter, q = Words.norm(query)
        let fs = f.str("status", "all"), fmt = f.str("format", "all"), genre = f.str("genre"), col = f.str("col"), ser = f.str("series", "all")
        let hideDone = f.bool("hideDone")
        var list = books.filter { b in
            if fs == "lent" {
                if !(b.format == .physical && (b.loan.bool("lent") || b.loan.bool("borrowed"))) { return false }
            } else if fs != "all" && b.status.rawValue != fs { return false }
            if hideDone && b.status == .done && fs != "done" { return false }
            if fmt != "all" && b.format.rawValue != fmt { return false }
            if !genre.isEmpty && !b.genres.contains(genre) { return false }
            if !col.isEmpty && !b.cols.contains(col) { return false }
            if ser == "series" && !b.series { return false }
            if ser == "single" && b.series { return false }
            if !q.isEmpty && !Words.norm([b.title, b.author, b.translator, b.narrator, b.cols.joined(separator: " "), b.genres.joined(separator: " ")].joined(separator: " ")).contains(q) { return false }
            return true
        }
        let asc = st.dir == "asc"
        func num(_ b: Book) -> Double {
            switch st.sort {
            case "added": return b.added
            case "started": return b.start ?? 0
            case "finished": return b.finish ?? 0
            case "progress": return b.pct ?? -1
            case "rating": return b.rating
            case "length": return b.sumTotal
            default: return lastTs(b)
            }
        }
        if st.sort == "title" || st.sort == "author" {
            let ar = Locale(identifier: "ar")
            list.sort { x, y in
                let a = Words.norm(st.sort == "title" ? x.title : x.author), b = Words.norm(st.sort == "title" ? y.title : y.author)
                let c = a.compare(b, locale: ar)
                return asc ? c == .orderedAscending : c == .orderedDescending
            }
        } else {
            let keys = Dictionary(uniqueKeysWithValues: list.map { ($0.id, num($0)) })
            list.sort { asc ? (keys[$0.id] ?? 0) < (keys[$1.id] ?? 0) : (keys[$0.id] ?? 0) > (keys[$1.id] ?? 0) }
        }
        return list
    }

    /// Collection name → how many books carry it.
    var allCols: [String: Int] {
        var m: [String: Int] = [:]
        for b in books { for c in b.cols { m[c, default: 0] += 1 } }
        return m
    }

    /// The status line under a book's title (statusText).
    func statusText(_ b: Book) -> String {
        let v = b.verbs
        if timer?.str("bookId") == b.id { return v.sess + " جارية" }
        if b.isNovel, let n = b.novel, b.status == .reading, !n.isEpub {
            if n.unread > 0 { return Words.cnt(Double(n.unread), ["فصل ما قرأته", "فصلان ما قرأتهما", "فصول ما قرأتها", "فصلًا ما قرأته"]) }
            if n.ongoing { return "ملحّق بآخر فصل" }
        }
        switch b.status {
        case .want: return "لم تبدأ بعد"
        case .done: return "أنهيته" + (b.rating > 0 ? " · " + Words.stars(b.rating) : "")
        case .dnf: return "توقفت عنه"
        case .reading:
            return (b.isAudio ? "تستمع له" : "تقرأه") + (b.pct.map { " · \(Int(($0 * 100).rounded()))%" } ?? "") + (b.readNo > 1 ? " · القراءة " + Words.ord(b.readNo) : "")
        }
    }

    /// The main button's words (readLabel).
    func readLabel(_ b: Book) -> String {
        let v = b.verbs
        if let n = b.novel { return n.curLabel.isEmpty ? "ابدأ القراءة" : "تابع · " + n.curLabel }
        if timer?.str("bookId") == b.id { return "العودة للجلسة" }
        if b.status == .done { return v.again }
        if b.status == .reading || b.pos > 0 { return v.cont }
        return v.start
    }
}
