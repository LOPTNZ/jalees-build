import SwiftUI
import UIKit

// إنجازاتي: the numbers behind goals, stats and achievements (inventory-2, sections 6.12, 6.13 and 7),
// worked out from the sessions, the reads and the notebook each time, as the web app did. Nothing is cached.

struct FinishedRead {
    let book: Book
    let finish: Double
    let rating: Double
}

struct Streak {
    var cur = 0
    var best = 0
    var todayHas = false
}

/// Noon, n days ago.
func dayAt(_ n: Int) -> Date {
    let cal = Calendar.current
    let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    return cal.date(byAdding: .day, value: -n, to: noon) ?? noon
}

extension AppState {
    /// Every finished read: earlier reads from the history, plus the current one when the book is done.
    var finishedReads: [FinishedRead] {
        var out: [FinishedRead] = []
        for b in books {
            for h in b.history where h.num("finish") > 0 {
                out.append(FinishedRead(book: b, finish: h.num("finish"), rating: h.num("rating")))
            }
            if b.status == .done { out.append(FinishedRead(book: b, finish: b.finish ?? 0, rating: b.rating)) }
        }
        return out
    }

    /// Books finished at least once.
    var finishedBooks: [Book] { books.filter { $0.status == .done || $0.history.contains { $0.num("finish") > 0 } } }

    var finishedThisYear: Int {
        let cal = Calendar.current, y = cal.component(.year, from: Date())
        return finishedReads.filter { $0.finish > 0 && cal.component(.year, from: Millis.date($0.finish)) == y }.count
    }

    func unitsRead(_ u: String) -> Double { sessions.reduce(0) { $0 + ($1.unit == u ? $1.units : 0) } }
    var totalMin: Double { sessions.reduce(0) { $0 + $1.minutes } }
    func countAll(_ k: NoteKind) -> Int { books.reduce(0) { $0 + $1.raw.arr(k.listKey).count } }

    /// Days in a row with reading. Today doesn't break the run until it ends; the best run ever.
    var streak: Streak {
        let m = minutesByDay()
        func has(_ n: Int) -> Bool { (m[Words.dkey(Millis.ms(dayAt(n)))] ?? 0) > 0 }
        var s = Streak()
        s.todayHas = has(0)
        var i = s.todayHas ? 0 : 1
        while i < 800 && has(i) { s.cur += 1; i += 1 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let nums: [Int] = m.compactMap { k, v in
            guard v > 0 else { return nil }
            let p = k.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3, let d = utc.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return nil }
            return Int((d.timeIntervalSince1970 / 86400).rounded())
        }.sorted()
        var run = 0
        var prev: Int?
        for n in nums {
            run = (prev != nil && n == prev! + 1) ? run + 1 : 1
            if run > s.best { s.best = run }
            prev = n
        }
        return s
    }

    /// Days the daily goal was met.
    var goalDays: Int {
        let g = Double(goals.daily)
        return minutesByDay().values.filter { $0 >= g }.count
    }

    /// Book reviews, earlier reads' reviews and volume reviews with text.
    var reviewsCount: Int {
        var n = 0
        for b in books {
            if !b.review.isEmpty { n += 1 }
            n += b.history.filter { !$0.str("review").isEmpty }.count
            n += b.volReviews.values.filter { v in
                if case .object(let o) = v { return !o.str("review").isEmpty }
                return false
            }.count
        }
        return n
    }

    var langsRead: Int { Set(finishedBooks.map(\.lang)).count }

    /// Minutes spent on audiobooks.
    var listenMin: Double {
        var audio: Set<String> = []
        for b in books where b.isAudio { audio.insert(b.id) }
        return sessions.reduce(0) { $0 + (audio.contains($1.bookId) ? $1.minutes : 0) }
    }

    func sessionStarted(_ test: (Int) -> Bool) -> Bool {
        sessions.contains { test(Calendar.current.component(.hour, from: Millis.date($0.start))) }
    }
}

// MARK: - the 40 achievements

struct Achievement: Identifiable {
    let id: String
    let group: String
    let title: String
    let detail: String
    let icon: String
    let goal: Double
    let value: (AppState) -> Double
}

enum Achievements {
    static let groups = ["الكتب", "الصفحات والفصول", "الوقت والاستمرار", "الدفتر", "مميزة"]

    private static func a(_ id: String, _ g: Int, _ t: String, _ d: String, _ ic: String, _ goal: Double, _ c: @escaping (AppState) -> Double) -> Achievement {
        Achievement(id: id, group: groups[g], title: t, detail: d, icon: ic, goal: goal, value: c)
    }
    private static func flag(_ b: Bool) -> Double { b ? 1 : 0 }

    static let all: [Achievement] = [
        a("b1", 0, "أول كتاب", "أنهِ أول كتاب", "book.closed", 1) { Double($0.finishedReads.count) },
        a("b5", 0, "خمسة كتب", "أنهِ 5 كتب", "book.closed", 5) { Double($0.finishedReads.count) },
        a("b10", 0, "رف كامل", "أنهِ 10 كتب", "books.vertical", 10) { Double($0.finishedReads.count) },
        a("b25", 0, "قارئ نهم", "أنهِ 25 كتابًا", "books.vertical", 25) { Double($0.finishedReads.count) },
        a("b50", 0, "نصف المئة", "أنهِ 50 كتابًا", "trophy", 50) { Double($0.finishedReads.count) },
        a("b100", 0, "المئوية", "أنهِ 100 كتاب", "trophy", 100) { Double($0.finishedReads.count) },
        a("yr", 0, "تحدي السنة", "حقق هدف السنة", "flag", 1) { flag($0.finishedThisYear >= $0.goals.year) },
        a("p100", 1, "مئة صفحة", "اقرأ 100 صفحة", "book.closed", 100) { $0.unitsRead("page") },
        a("p1k", 1, "ألف صفحة", "اقرأ 1,000 صفحة", "book.closed", 1000) { $0.unitsRead("page") },
        a("p5k", 1, "خمسة آلاف صفحة", "اقرأ 5,000 صفحة", "square.stack.3d.up", 5000) { $0.unitsRead("page") },
        a("p10k", 1, "عشرة آلاف صفحة", "اقرأ 10,000 صفحة", "trophy", 10000) { $0.unitsRead("page") },
        a("c100", 1, "مئة فصل", "اقرأ أو استمع إلى 100 فصل", "ipad", 100) { $0.unitsRead("chapter") },
        a("c1k", 1, "ألف فصل", "1,000 فصل", "ipad", 1000) { $0.unitsRead("chapter") },
        a("epic", 1, "ملحمة", "أنهِ كتابًا فيه 800 صفحة أو 1,000 فصل أو 20 ساعة استماع", "sparkles", 1) { s in
            flag(s.finishedBooks.contains { b in
                switch b.unit {
                case .page: return b.sumTotal >= 800
                case .min: return b.sumTotal >= 1200
                case .chapter: return b.sumTotal >= 1000
                }
            })
        },
        a("h1", 2, "أول ساعة", "ساعة قراءة", "clock", 1) { $0.totalMin / 60 },
        a("h10", 2, "عشر ساعات", "10 ساعات", "clock", 10) { $0.totalMin / 60 },
        a("h50", 2, "خمسون ساعة", "50 ساعة", "clock", 50) { $0.totalMin / 60 },
        a("h100", 2, "مئة ساعة", "100 ساعة", "trophy", 100) { $0.totalMin / 60 },
        a("s3", 2, "بداية عادة", "3 أيام متتالية", "flame", 3) { Double($0.streak.best) },
        a("s7", 2, "أسبوع كامل", "7 أيام متتالية", "flame", 7) { Double($0.streak.best) },
        a("s30", 2, "شهر بلا انقطاع", "30 يومًا متتالية", "flame", 30) { Double($0.streak.best) },
        a("s100", 2, "مئة يوم", "100 يوم متتالي", "trophy", 100) { Double($0.streak.best) },
        a("gd30", 2, "عادة راسخة", "حقق هدفك اليومي في 30 يومًا", "flag", 30) { Double($0.goalDays) },
        a("mar", 2, "ماراثون", "جلسة واحدة ساعتين أو أكثر", "clock", 1) { s in flag(s.sessions.contains { $0.minutes >= 120 }) },
        a("q1", 3, "أول اقتباس", "احفظ أول اقتباس", "quote.opening", 1) { Double($0.countAll(.quote)) },
        a("q25", 3, "جامع الاقتباسات", "25 اقتباسًا", "quote.opening", 25) { Double($0.countAll(.quote)) },
        a("t10", 3, "عقل مشتعل", "10 أفكار", "lightbulb", 10) { Double($0.countAll(.thought)) },
        a("w20", 3, "قاموس صغير", "20 كلمة", "character.book.closed", 20) { Double($0.countAll(.word)) },
        a("w100", 3, "قاموس كبير", "100 كلمة", "character.book.closed", 100) { Double($0.countAll(.word)) },
        a("ch10", 3, "راوي الشخصيات", "10 شخصيات", "person", 10) { Double($0.countAll(.char)) },
        a("rv5", 3, "ناقد", "اكتب 5 مراجعات", "pencil", 5) { Double($0.reviewsCount) },
        a("night", 4, "سهران مع كتاب", "جلسة بعد منتصف الليل", "moon", 1) { flag($0.sessionStarted { $0 >= 0 && $0 < 4 }) },
        a("dawn", 4, "قارئ الفجر", "جلسة بين الرابعة والسابعة صباحًا", "sun.horizon", 1) { flag($0.sessionStarted { $0 >= 4 && $0 < 7 }) },
        a("re", 4, "العودة للحبيب", "أعد قراءة كتاب", "repeat", 1) { s in flag(s.books.contains { !$0.history.isEmpty }) },
        a("ser", 4, "السلسلة كاملة", "أنهِ سلسلة كاملة", "square.stack.3d.up", 1) { s in
            flag(s.books.contains { $0.series && ($0.status == .done || $0.history.contains { $0.num("finish") > 0 }) })
        },
        a("lang", 4, "بلا حدود", "أنهِ كتبًا بثلاث لغات", "globe", 3) { Double($0.langsRead) },
        a("aud", 4, "أذن صاغية", "أنهِ كتابًا صوتيًا", "headphones", 1) { s in flag(s.finishedBooks.contains { $0.isAudio }) },
        a("aud10", 4, "رفيق الطريق", "10 ساعات استماع لكتب صوتية", "headphones", 10) { $0.listenMin / 60 },
        a("aud50", 4, "مستمع عتيق", "50 ساعة استماع", "headphones", 50) { $0.listenMin / 60 },
        a("lib50", 4, "صاحب مكتبة", "50 كتابًا في مكتبتك", "books.vertical", 50) { Double($0.books.count) },
    ]

    /// When it was unlocked (nil while locked).
    static func unlockedAt(_ id: String, _ s: AppState) -> Double? {
        switch s.ach[id] {
        case .number(let n)?: return n > 0 ? n : nil
        case .bool(true)?: return 0
        default: return nil
        }
    }

    static func isOn(_ a: Achievement, _ s: AppState) -> Bool { unlockedAt(a.id, s) != nil || a.value(s) >= a.goal }

    /// Unlocks what is newly reached. The first check after install records quietly; later ones show a toast each.
    @MainActor static func check() {
        let lib = Library.shared
        let s = lib.state
        var ach = s.ach
        var fresh: [Achievement] = []
        let now = Millis.now
        for a in all where unlockedAt(a.id, s) == nil && a.value(s) >= a.goal {
            ach[a.id] = .number(now)
            fresh.append(a)
        }
        if !s.rest.bool("achInit") {
            lib.change { $0.ach = ach; $0.rest["achInit"] = .bool(true) }
            return
        }
        guard !fresh.isEmpty else { return }
        lib.change { $0.ach = ach }
        Haptics.play("success")
        for a in fresh { Toaster.show("إنجاز جديد: " + a.title, achievement: true) }
    }
}
