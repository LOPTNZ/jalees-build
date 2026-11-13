import SwiftUI
import UIKit

// إنجازاتي (inventory-2, 2.5–2.7 and section 7): goals and stats on one page, a switch at the top.

struct ProgressTab: View {
    @ObservedObject private var lib = Library.shared
    @Environment(\.look) private var L
    @State private var sub = "goals"
    @State private var range = 7

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("إنجازاتي").font(JFont.display(28, .bold)).foregroundStyle(Color(L.ink)).id("top")
                    JSeg(options: [("goals", "الأهداف"), ("stats", "الإحصائيات")], value: $sub)
                        .padding(.bottom, 4)
                    if sub == "goals" { GoalsPage(state: lib.state) } else { StatsPage(state: lib.state, range: $range) }
                }
                .padding(.horizontal, 16).padding(.bottom, 40)
            }
            .onReceive(NotificationCenter.default.publisher(for: .tabRetap)) { n in
                if (n.object as? String) == "progress" { withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("top", anchor: .top) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .progressShow)) { n in
                // debug routes: "goals", "stats", or either with a section to scroll to ("goals:ach")
                let parts = ((n.object as? String) ?? "goals").split(separator: ":").map(String.init)
                sub = parts[0]
                if parts.count > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { proxy.scrollTo(parts[1], anchor: .top) } }
            }
        }
        .statusBarBackdrop(Color(L.bg))
        .background(Color(L.bg).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension Notification.Name {
    static let progressShow = Notification.Name("jalees.progressShow")
}

private struct H2: View {
    let text: String
    @Environment(\.look) private var L
    var body: some View { Text(text).font(JFont.display(15 * 1.2)).foregroundStyle(Color(L.ink)) }
}

private struct Small: View {
    let text: String
    @Environment(\.look) private var L
    var body: some View { Text(text).font(JFont.body(15 * 0.87)).foregroundStyle(Color(L.ink2)) }
}

/// .bar: a thin rounded progress line.
struct JBar: View {
    let value: Double
    var height: CGFloat = 6
    @Environment(\.look) private var L
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(L.surface2))
                Capsule().fill(Color(L.primary)).frame(width: g.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - الأهداف

private struct GoalsPage: View {
    let state: AppState
    @Environment(\.look) private var L

    var body: some View {
        let g = state.goals, today = state.todayMin, st = state.streak, fy = state.finishedThisYear
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Small(text: "قراءة اليوم")
                    H2(text: today >= Double(g.daily) ? "حققت هدف اليوم" : "باقي \(max(0, Int((Double(g.daily) - today).rounded(.up)))) دقيقة")
                    if st.cur > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                            Text(Words.cnt(Double(st.cur), Words.days) + (st.cur > 1 ? " متتالية" : ""))
                        }
                        .font(JFont.body(15, .medium)).foregroundStyle(Color(L.accentInk))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GoalRing(today: today, goal: g.daily)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack { H2(text: "الهدف اليومي"); Spacer(); Small(text: "بالدقائق") }
                GoalStepper(value: g.daily, label: "دقائق الهدف اليومي") { d in
                    Library.shared.change { $0.goals.daily = min(300, max(5, $0.goals.daily + d * 5)) }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack { H2(text: "هدف السنة"); Spacer(); Small(text: "\(fy) من \(g.year)") }
                JBar(value: Double(fy) / Double(max(1, g.year)))
                GoalStepper(value: g.year, label: "كتب السنة") { d in
                    Library.shared.change { $0.goals.year = min(300, max(1, $0.goals.year + d)) }
                    Achievements.check()
                }
                Text(fy > 0 ? "بهذا المعدل تنهي نحو \(Words.cnt(Double(fy) / yearFraction(), Words.books)) هذه السنة." : "أنهِ أول كتاب هذه السنة ليبدأ حساب وتيرتك.")
                    .font(JFont.body(15)).foregroundStyle(Color(L.ink2))
            }

            AchievementsList(state: state).id("ach")
        }
    }

    /// How much of this year has gone (at least 2%).
    private func yearFraction() -> Double {
        let cal = Calendar.greg, y = cal.component(.year, from: Date())
        guard let y0 = cal.date(from: DateComponents(year: y, month: 1, day: 1)),
              let y1 = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1)) else { return 1 }
        return min(1, max(0.02, Date().timeIntervalSince(y0) / y1.timeIntervalSince(y0)))
    }
}

private struct GoalRing: View {
    let today: Double
    let goal: Int
    @Environment(\.look) private var L
    var body: some View {
        let p = min(1, max(0, today / Double(max(1, goal))))
        ZStack {
            Circle().stroke(Color(L.surface2), lineWidth: 10)
            if p > 0 {
                Circle().trim(from: 0, to: p).stroke(Color(L.primary), style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text("\(Int(today.rounded()))").font(JFont.display(15 * 1.9)).foregroundStyle(Color(L.ink))
                Text("من \(goal) د").font(JFont.body(15 * 0.8)).foregroundStyle(Color(L.ink2))
            }
        }
        .padding(5)
        .frame(width: 128, height: 128)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(today.rounded())) من \(goal) دقيقة")
    }
}

/// .stepper: − value +, the value read-only.
private struct GoalStepper: View {
    let value: Int
    let label: String
    let step: (Int) -> Void
    @Environment(\.look) private var L
    var body: some View {
        HStack(spacing: 8) {
            key("−", -1, "أنقص")
            Text("\(value)").font(JFont.body(15 * 1.25, .semibold)).foregroundStyle(Color(L.ink))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.bg)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
                .accessibilityLabel(label)
                .accessibilityValue("\(value)")
            key("+", 1, "زد")
        }
        .frame(maxWidth: 280)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func key(_ t: String, _ d: Int, _ a: String) -> some View {
        Button { step(d); Haptics.play("sel") } label: {
            Text(t).font(.system(size: 22)).foregroundStyle(Color(L.ink))
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(L.surface)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a)
    }
}

// MARK: - الإنجازات

private struct AchievementsList: View {
    let state: AppState
    @Environment(\.look) private var L
    var body: some View {
        let on = Dictionary(uniqueKeysWithValues: Achievements.all.map { ($0.id, Achievements.isOn($0, state)) })
        VStack(alignment: .leading, spacing: 18) {
            HStack { H2(text: "الإنجازات"); Spacer(); Small(text: "\(on.values.filter { $0 }.count) من \(Achievements.all.count)") }
            ForEach(Achievements.groups, id: \.self) { g in
                VStack(alignment: .leading, spacing: 10) {
                    Text(g).font(JFont.body(15 * 1.02, .semibold)).foregroundStyle(Color(L.ink2))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(Achievements.all.filter { $0.group == g }) { a in
                            BadgeView(a: a, state: state, on: on[a.id] ?? false)
                        }
                    }
                }
            }
        }
    }
}

private struct BadgeView: View {
    let a: Achievement
    let state: AppState
    let on: Bool
    @Environment(\.look) private var L
    var body: some View {
        let cur = a.value(state), p = min(1, max(0, cur / a.goal))
        HStack(spacing: 10) {
            ZStack {
                if on {
                    Circle().fill(LinearGradient(colors: [Color(hex: "#f6d27a"), Color(hex: "#c98a1d")], startPoint: .top, endPoint: .bottom))
                        .shadow(color: Color(hex: "#c98a1d").opacity(0.6), radius: 5, y: 4)
                } else {
                    Circle().stroke(Color(L.surface2), lineWidth: 5).padding(5)
                    if p > 0 {
                        Circle().trim(from: 0, to: p).stroke(Color(L.primary), style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)).padding(5)
                    }
                }
                Image(systemName: a.icon).font(.system(size: 19, weight: .medium))
                    .foregroundStyle(on ? Color(hex: "#3b2606") : Color(L.ink2))
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(JFont.body(15 * 0.92, .semibold)).foregroundStyle(Color(L.ink)).lineLimit(2)
                Text(a.detail).font(JFont.body(15 * 0.78)).foregroundStyle(Color(L.ink2)).lineLimit(3)
                Text(status(cur)).font(JFont.body(15 * 0.78)).foregroundStyle(Color(L.ink2))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(L.surface)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(L.line), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func status(_ cur: Double) -> String {
        if on {
            if let at = Achievements.unlockedAt(a.id, state), at > 0 { return "تحقق " + Words.date(at) }
            return "تحقق"
        }
        return a.goal > 1 ? "\(Words.n0(cur.rounded(.down))) / \(Words.n0(a.goal))" : "لم يتحقق بعد"
    }
}

// MARK: - الإحصائيات

private struct StatsPage: View {
    let state: AppState
    @Binding var range: Int
    @Environment(\.look) private var L

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            YearWrap(state: state)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    H2(text: "وقت القراءة اليومي")
                    Spacer(minLength: 8)
                    JSeg(options: [(7, "7 أيام"), (30, "30 يومًا")], value: $range).frame(width: 170)
                }
                JPanel { DailyChart(state: state, days: range) }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack { H2(text: "أيام القراءة"); Spacer(); Small(text: "آخر 18 أسبوعًا") }
                Heatmap(state: state)
            }

            Facts(items: facts(), light: false).id("facts")

            VStack(alignment: .leading, spacing: 4) {
                H2(text: "الوقت حسب الكتاب")
                let per = perBook()
                if per.isEmpty { Small(text: "يظهر هنا بعد أول جلسة.").padding(.top, 6) } else { BarList(rows: per) }
            }
            VStack(alignment: .leading, spacing: 4) {
                H2(text: "التصنيفات في مكتبتك")
                let gr = genres()
                if gr.isEmpty { Small(text: "أضف تصنيفات لكتبك.").padding(.top, 6) } else { BarList(rows: gr) }
            }
            VStack(alignment: .leading, spacing: 4) {
                H2(text: "طريقة الامتلاك")
                BarList(rows: formats())
            }
        }
    }

    private func facts() -> [(String, String)] {
        let s = state, tm = s.totalMin, ns = s.sessions.count, listen = s.listenMin
        let spP = s.speed(s.sessions, .page), spC = s.speed(s.sessions, .chapter)
        return [
            (tm > 0 ? Words.fmtMin(tm) : "0 د", "وقت القراءة"),
            (Words.n0(s.unitsRead("page")), "صفحة"),
            (Words.n0(s.unitsRead("chapter")), "فصل"),
            ("\(s.finishedReads.count)", "قراءة مكتملة"),
            (spP.map { Words.n0($0) } ?? "—", "صفحة في الساعة"),
            (spC.map { Words.n0($0) } ?? "—", "فصل في الساعة"),
            (ns > 0 ? Words.fmtMin(tm / Double(ns)) : "—", "متوسط الجلسة"),
            (listen > 0 ? Words.fmtMin(listen) : "0 د", "استماع لكتب صوتية"),
            ("\(s.streak.best)", "أطول سلسلة أيام"),
            ("\(s.countAll(.quote))", "اقتباس"),
            ("\(s.countAll(.thought))", "فكرة"),
            ("\(s.countAll(.word))", "كلمة"),
            ("\(s.countAll(.char))", "شخصية"),
        ]
    }

    private func perBook() -> [BarRow] {
        var mins: [String: Double] = [:]
        for x in state.sessions { mins[x.bookId, default: 0] += x.minutes }
        let rows = state.books.compactMap { b -> BarRow? in
            let m = mins[b.id] ?? 0
            return m > 0 ? BarRow(name: b.title, value: m, text: Words.fmtMin(m), book: b.id) : nil
        }
        return Array(stableSorted(rows).prefix(8))
    }

    private func genres() -> [BarRow] {
        var order: [String] = []
        var m: [String: Double] = [:]
        for b in state.books { for g in b.genres { if m[g] == nil { order.append(g) }; m[g, default: 0] += 1 } }
        let rows = order.map { BarRow(name: $0, value: m[$0]!, text: "\(Int(m[$0]!))", book: nil) }
        return Array(stableSorted(rows).prefix(8))
    }

    /// Every way of owning a book, web novels too (the web app left them out by mistake).
    private func formats() -> [BarRow] {
        let rows = BookFormat.allCases.compactMap { f -> BarRow? in
            let n = state.books.filter { $0.format == f }.count
            return n > 0 ? BarRow(name: f.label, value: Double(n), text: "\(n)", book: nil) : nil
        }
        return stableSorted(rows)
    }

    private func stableSorted(_ rows: [BarRow]) -> [BarRow] {
        rows.enumerated().sorted { $0.element.value != $1.element.value ? $0.element.value > $1.element.value : $0.offset < $1.offset }.map(\.element)
    }
}

private struct Facts: View {
    let items: [(String, String)]
    let light: Bool
    @Environment(\.look) private var L
    var body: some View {
        let line = light ? Color.white.opacity(0.15) : Color(L.line)
        VStack(spacing: 0) {
            line.frame(height: 1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(items[i].0).font(JFont.display(15 * 1.4)).lineLimit(1).minimumScaleFactor(0.6)
                            .foregroundStyle(light ? Color(hex: "#eef6f3") : Color(L.ink))
                        Text(items[i].1).font(JFont.body(15 * 0.84))
                            .foregroundStyle(light ? Color(hex: "#eef6f3").opacity(0.75) : Color(L.ink2))
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { line.frame(height: 1) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct BarRow: Identifiable {
    var id: String { name }
    let name: String
    let value: Double
    let text: String
    let book: String?
}

private struct BarList: View {
    let rows: [BarRow]
    @Environment(\.look) private var L
    var body: some View {
        let mx = max(1, rows.first?.value ?? 1)
        VStack(spacing: 0) {
            ForEach(rows) { r in
                let inner = VStack(spacing: 5) {
                    HStack(spacing: 12) {
                        Text(r.name).font(JFont.body(15)).foregroundStyle(Color(L.ink)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(r.text).font(JFont.body(15)).foregroundStyle(Color(L.ink2))
                    }
                    JBar(value: max(0.03, r.value / mx))
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                if let id = r.book, let b = Library.shared.state.book(id) {
                    Button { OpenBook.open(b) } label: { inner }.buttonStyle(.plain)
                } else {
                    inner
                }
            }
        }
    }
}

// MARK: - حصاد السنة

private struct YearWrap: View {
    let state: AppState
    @Environment(\.look) private var L

    var body: some View {
        let cal = Calendar.greg, y = cal.component(.year, from: Date())
        let y0 = Millis.ms(cal.date(from: DateComponents(year: y, month: 1, day: 1)) ?? Date())
        let reads = state.finishedReads.filter { $0.finish >= y0 }
        let ss = state.sessions.filter { $0.start >= y0 }
        let mins = ss.reduce(0) { $0 + $1.minutes }
        let pages = ss.reduce(0) { $0 + ($1.unit == "page" ? $1.units : 0) }
        let chs = ss.reduce(0) { $0 + ($1.unit == "chapter" ? $1.units : 0) }
        let ink = Color(hex: "#eef6f3")
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("حصاد \(String(y))").font(JFont.display(15 * 1.2)).foregroundStyle(ink)
                Spacer()
                Text("حتى اليوم").font(JFont.body(15 * 0.87)).foregroundStyle(ink.opacity(0.75))
            }
            Facts(items: [("\(reads.count)", "كتاب أنهيته"), (mins > 0 ? Words.fmtMin(mins) : "0 د", "قراءة واستماع"),
                          (Words.n0(pages), "صفحة"), (Words.n0(chs), "فصل")], light: true)
            let kv = rows(reads, ss)
            if !kv.isEmpty {
                VStack(spacing: 8) {
                    ForEach(kv, id: \.0) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(r.0).foregroundStyle(ink.opacity(0.7))
                            Spacer(minLength: 0)
                            Text(r.1).foregroundStyle(ink).multilineTextAlignment(.trailing)
                        }
                        .font(JFont.body(15 * 0.93))
                    }
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Color(hue: 165 / 360, saturation: 0.40, lightness: 0.22), Color(hue: 190 / 360, saturation: 0.40, lightness: 0.12)],
                           startPoint: .topTrailing, endPoint: .bottomLeading),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func rows(_ reads: [FinishedRead], _ ss: [Session]) -> [(String, String)] {
        var out: [(String, String)] = []
        var order: [String] = []
        var gm: [String: Int] = [:]
        for r in reads { for g in r.book.genres { if gm[g] == nil { order.append(g) }; gm[g, default: 0] += 1 } }
        if let top = order.max(by: { (gm[$0] ?? 0) < (gm[$1] ?? 0) || ((gm[$0] ?? 0) == (gm[$1] ?? 0) && order.firstIndex(of: $0)! > order.firstIndex(of: $1)!) }) {
            out.append(("تصنيفك الأكثر", top))
        }
        var best: FinishedRead?
        for r in reads where r.rating > 0 { if best == nil || r.rating > best!.rating { best = r } }
        if let b = best {
            let n = Int(b.rating.rounded())
            out.append(("الأعلى تقييمًا", b.book.title + " " + String(repeating: "★", count: max(0, min(5, n))) + String(repeating: "☆", count: max(0, 5 - n))))
        }
        var mm = [Double](repeating: 0, count: 12)
        var any = false
        for s in ss { mm[Calendar.greg.component(.month, from: Millis.date(s.start)) - 1] += s.minutes; any = true }
        if any {
            var top = 0
            for i in 1..<12 where mm[i] > mm[top] { top = i }
            out.append(("أنشط شهر", Words.months[top]))
        }
        return out
    }
}

extension Color {
    /// hsl(h, s, l) as CSS writes it, each from 0 to 1.
    init(hue h: Double, saturation s: Double, lightness l: Double) {
        let v = l + s * min(l, 1 - l)
        let sv = v == 0 ? 0 : 2 * (1 - l / v)
        self.init(hue: h, saturation: sv, brightness: v)
    }
}

// MARK: - the daily chart

/// Minutes a day for the last 7 or 30 days, today at the far left as the web app drew it, with the goal as a dashed line.
private struct DailyChart: View {
    let state: AppState
    let days: Int
    @Environment(\.look) private var L
    private static let letters = ["ح", "ن", "ث", "ر", "خ", "ج", "س"]

    var body: some View {
        let goal = Double(state.goals.daily)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                Canvas { ctx, size in draw(ctx, size, goal) }
                    .frame(width: geo.size.width, height: 200)
            }
            .frame(height: 200)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("وقت القراءة اليومي بالدقائق لآخر \(days) يومًا")

            HStack(spacing: 14) {
                legend(Color(L.primary), "حققت الهدف")
                legend(Color(L.barLo), "أقل من الهدف")
                HStack(spacing: 6) {
                    Path { p in p.move(to: .init(x: 0, y: 1)); p.addLine(to: .init(x: 16, y: 1)) }
                        .stroke(Color(L.accent), style: StrokeStyle(lineWidth: 2, dash: [4, 3])).frame(width: 16, height: 2)
                    Text("الهدف (\(Int(goal)) د)")
                }
            }
            .font(JFont.body(15 * 0.82)).foregroundStyle(Color(L.ink2))
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 12, height: 12); Text(t) }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ goal: Double) {
        let W = size.width, H: CGFloat = 200, padR: CGFloat = 30, padL: CGFloat = 6, padT: CGFloat = 10, padB: CGFloat = 24
        let m = state.minutesByDay(), n = days
        struct Day { let v: Double; let dow: Int; let dom: Int; let k: Int }
        var vals: [Day] = []
        let cal = Calendar.greg
        for j in 0..<n {
            let d = dayAt(n - 1 - j)
            vals.append(Day(v: m[Words.dkey(Millis.ms(d))] ?? 0, dow: cal.component(.weekday, from: d) - 1, dom: cal.component(.day, from: d), k: n - 1 - j))
        }
        let raw = max(goal, 10, vals.map(\.v).max() ?? 0)
        let step = [10.0, 15, 20, 30, 60, 90, 120, 180, 240].first { raw / $0 <= 4 } ?? 300
        let mx = (raw / step).rounded(.up) * step
        let pw = W - padR - padL, ph = H - padT - padB, bw = pw / CGFloat(n), barW = min(28, bw * 0.62)
        func X(_ i: Int) -> CGFloat { W - padR - (CGFloat(i) + 0.5) * bw }
        func Y(_ v: Double) -> CGFloat { padT + ph - CGFloat(v / mx) * ph }
        let txt = Color(L.ink2)
        var t = 0.0
        while t <= mx {
            var p = Path(); p.move(to: .init(x: padL, y: Y(t))); p.addLine(to: .init(x: W - padR, y: Y(t)))
            ctx.stroke(p, with: .color(Color(L.line)), lineWidth: 1)
            ctx.draw(Text("\(Int(t))").font(JFont.body(11)).foregroundColor(txt), at: .init(x: W - padR + 6, y: Y(t)), anchor: .leading)
            t += step
        }
        for (i, o) in vals.enumerated() {
            let x = X(i)
            if o.v > 0 {
                let h = max(2, CGFloat(o.v / mx) * ph)
                let r = CGRect(x: x - barW / 2, y: padT + ph - h, width: barW, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Color(o.v >= goal ? L.primary : L.barLo)))
            }
            let label: String? = n <= 7 ? Self.letters[o.dow] : (o.k % 5 == 0 ? "\(o.dom)" : nil)
            if let lb = label {
                let today = o.k == 0
                ctx.draw(Text(lb).font(JFont.body(11, today ? .bold : .regular)).foregroundColor(today ? Color(L.accentInk) : txt),
                         at: .init(x: x, y: H - 11), anchor: .center)
            }
        }
        var g = Path(); g.move(to: .init(x: padL, y: Y(goal))); g.addLine(to: .init(x: W - padR, y: Y(goal)))
        ctx.stroke(g, with: .color(Color(L.accent)), style: StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
    }
}

// MARK: - the heatmap

/// 18 weeks of reading days, a column a week (Sunday on top), the oldest week at the right.
private struct Heatmap: View {
    let state: AppState
    @Environment(\.look) private var L

    private struct Cell: Identifiable { let id: Int; let level: Int; let ms: Double; let minutes: Double }
    @State private var picked: Cell?
    private struct Week: Identifiable { let id: Int; let month: String; let cells: [Cell] }

    var body: some View {
        let weeks = build()
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    ForEach(weeks) { w in
                        Text(w.month).font(JFont.body(10)).foregroundStyle(Color(L.ink2)).fixedSize()
                            .frame(width: 15, height: 16, alignment: .leading)
                    }
                }
                HStack(spacing: 3) {
                    ForEach(weeks) { w in
                        VStack(spacing: 3) {
                            ForEach(w.cells) { c in
                                square(c.level, 15)
                                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(L.ink).opacity(picked?.ms == c.ms ? 0.9 : 0), lineWidth: 1.5))
                                    .onTapGesture { if c.level >= 0 { picked = picked?.ms == c.ms ? nil : c; Haptics.play("sel") } }
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("خريطة أيام القراءة")
            // the web's tip on each day: tap a day to see it
            if let c = picked {
                Text(Words.date(c.ms) + ": " + (c.minutes > 0 ? Words.fmtMin(c.minutes) : "بدون قراءة"))
                    .font(JFont.body(15 * 0.86, .medium)).foregroundStyle(Color(L.ink))
            }
            HStack(spacing: 6) {
                Text("أقل")
                ForEach(0..<5) { l in square(l, 12) }
                Text("أكثر · حسب هدفك اليومي")
            }
            .font(JFont.body(15 * 0.82)).foregroundStyle(Color(L.ink2))
        }
    }

    private func square(_ level: Int, _ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s >= 15 ? 4 : 3, style: .continuous).fill(color(level)).frame(width: s, height: s)
    }

    private func color(_ l: Int) -> Color {
        switch l {
        case -1: return .clear
        case 1: return Color(L.surface2.mixed(with: L.primary, 0.28))
        case 2: return Color(L.surface2.mixed(with: L.primary, 0.52))
        case 3: return Color(L.surface2.mixed(with: L.primary, 0.78))
        case 4: return Color(L.primary)
        default: return Color(L.surface2)
        }
    }

    private func build() -> [Week] {
        let m = state.minutesByDay(), g = Double(state.goals.daily), cal = Calendar.greg
        let today = dayAt(0)
        let end = cal.date(byAdding: .day, value: 6 - (cal.component(.weekday, from: today) - 1), to: today) ?? today
        func day(_ off: Int) -> Date { cal.date(byAdding: .day, value: off, to: end) ?? end }
        var out: [Week] = []
        var lastM = -1
        for w in stride(from: 17, through: 0, by: -1) {
            var cells: [Cell] = []
            for d in 0..<7 {
                let dt = day(-w * 7 - (6 - d))
                let v = m[Words.dkey(Millis.ms(dt))] ?? 0
                let lv = dt > today ? -1 : v <= 0 ? 0 : v < g * 0.5 ? 1 : v < g ? 2 : v < g * 1.6 ? 3 : 4
                cells.append(Cell(id: d, level: lv, ms: Millis.ms(dt), minutes: v))
            }
            let first = day(-w * 7 - 6)
            let mo = cal.component(.month, from: first) - 1
            out.append(Week(id: w, month: mo != lastM ? Words.months[mo] : "", cells: cells))
            lastM = mo
        }
        return out
    }
}

extension UIColor {
    /// color-mix(in srgb, other t, self)
    func mixed(with o: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        o.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
