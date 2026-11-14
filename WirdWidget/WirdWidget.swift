import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - data

struct WirdEntry: TimelineEntry {
    let date: Date
    let snap: WSnap?
    let cover: UIImage?
}

enum WidgetData {
    static func load() -> (WSnap?, UIImage?) {
        guard let dir = SharedGroup.container else { return (nil, nil) }
        let snap = (try? Data(contentsOf: dir.appendingPathComponent("widget.json"))).flatMap { try? JSONDecoder().decode(WSnap.self, from: $0) }
        let img = UIImage(contentsOfFile: dir.appendingPathComponent("cover.jpg").path)
        return (snap, img)
    }

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.greg.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static let sample = WSnap(day: dayKey(Date()), today: 20, goal: 30, streak: 5, todayHas: true, year: 4, yearGoal: 12,
                              book: WBook(id: "", title: "لكنود", author: "إسلام جمال", pct: 0.3, pos: "ص 64 / 216", status: "reading", audio: false, cover: "", color: "#2c4a63"),
                              accent: "#5cc2ae")
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WirdEntry {
        WirdEntry(date: Date(), snap: WidgetData.sample, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WirdEntry) -> Void) {
        let (s, img) = WidgetData.load()
        completion(WirdEntry(date: Date(), snap: s ?? (context.isPreview ? WidgetData.sample : nil), cover: img))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WirdEntry>) -> Void) {
        let (s, img) = WidgetData.load()
        let now = Date()
        let midnight = Calendar.greg.startOfDay(for: now.addingTimeInterval(86_400))
        let entries = [WirdEntry(date: now, snap: s, cover: img), WirdEntry(date: midnight, snap: s, cover: img)]
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(120))))
    }
}

// MARK: - helpers

extension Color {
    init(hex: String?, fallback: Color) {
        let h = (hex ?? "").replacingOccurrences(of: "#", with: "")
        guard h.count == 6, let v = UInt64(h, radix: 16) else {
            self = fallback
            return
        }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension View {
    /// iOS 17 needs containerBackground; iOS 16 uses a plain background with our own padding.
    @ViewBuilder func widgetBackground<B: View>(_ bg: B, pad: CGFloat = 14) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { bg }
        } else {
            self.padding(pad).background(bg)
        }
    }
}

let teal = Color(red: 0.36, green: 0.76, blue: 0.68)

// MARK: - home & lock screen widget

struct BookWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WirdEntry

    private var snap: WSnap? { entry.snap }
    private var isToday: Bool { snap?.day == WidgetData.dayKey(entry.date) }
    private var minutes: Int { isToday ? (snap?.today ?? 0) : 0 }
    private var goal: Int { max(1, snap?.goal ?? 30) }
    private var streak: Int {
        guard let s = snap else { return 0 }
        if s.day == WidgetData.dayKey(entry.date) { return s.streak }
        let yesterday = WidgetData.dayKey(entry.date.addingTimeInterval(-86_400))
        return s.day == yesterday && s.todayHas ? s.streak : 0
    }
    private var accent: Color { Color(hex: snap?.accent, fallback: teal) }
    private var url: URL? {
        if let id = snap?.book?.id, !id.isEmpty { return URL(string: "wird://open?book=\(id)") }
        return URL(string: "wird://open")
    }

    var body: some View {
        content
            .environment(\.layoutDirection, Lang.direction)
            .widgetURL(url)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        default: small
        }
    }

    private var background: some View {
        LinearGradient(colors: [Color(hex: snap?.book?.color, fallback: Color(red: 0.11, green: 0.3, blue: 0.27)).opacity(0.95),
                                Color(red: 0.04, green: 0.07, blue: 0.06)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func coverView(_ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            if let img = entry.cover {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hex: snap?.book?.color, fallback: Color(red: 0.17, green: 0.29, blue: 0.39))
                    Text(snap?.book?.title ?? "").font(.system(size: 9, weight: .bold)).foregroundColor(.white).multilineTextAlignment(.center).padding(4)
                }
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    private var pctText: String {
        guard let p = snap?.book?.pct else { return "" }
        return "\(Int((p * 100).rounded()))%"
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "book.closed").font(.title2)
            Text("افتح جليس مرة عشان تظهر بياناتك").font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A web novel: the chapter you are at, and the new or unread chapters.
    private func novelLine(_ b: WBook) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let c = b.chapter, !c.isEmpty { Text(c).font(.system(size: 11, weight: .semibold)).lineLimit(1) }
            if let f = b.fresh, f > 0 {
                Text("\(f) \(f == 1 ? "فصل جديد" : (f <= 10 ? "فصول جديدة" : "فصلًا جديدًا"))").font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(accent.opacity(0.85))).foregroundColor(.black)
            } else if let u = b.unread, u > 0 {
                Text("\(u) غير مقروء").font(.system(size: 11)).foregroundColor(.white.opacity(0.8))
            }
        }
    }

    private var dailyLine: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill").foregroundColor(.orange)
            Text("\(streak)").fontWeight(.semibold)
            Spacer(minLength: 2)
            Text("\(minutes)/\(goal) د").foregroundColor(.white.opacity(0.8))
        }
        .font(.system(size: 11))
        .foregroundColor(.white)
    }

    private var small: some View {
        Group {
            if let b = snap?.book {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        coverView(44, 66)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.system(size: 14, weight: .bold)).lineLimit(3)
                            if !b.author.isEmpty { Text(b.author).font(.system(size: 10)).foregroundColor(.white.opacity(0.75)).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                    if b.novel == true {
                        novelLine(b)
                    } else if let p = b.pct {
                        HStack(spacing: 6) {
                            ProgressView(value: min(max(p, 0), 1)).tint(accent)
                            Text(pctText).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    dailyLine
                }
                .foregroundColor(.white)
            } else {
                empty
            }
        }
        .widgetBackground(background)
    }

    private var medium: some View {
        Group {
            if let b = snap?.book {
                HStack(spacing: 14) {
                    coverView(70, 105)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(b.audio ? "تستمع الآن" : (b.status == "reading" ? "تقرأ الآن" : "آخر كتاب")).font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                        Text(b.title).font(.system(size: 17, weight: .bold)).lineLimit(2)
                        if !b.author.isEmpty { Text(b.author).font(.system(size: 12)).foregroundColor(.white.opacity(0.75)).lineLimit(1) }
                        Spacer(minLength: 0)
                        if b.novel == true {
                            novelLine(b)
                        } else if let p = b.pct {
                            ProgressView(value: min(max(p, 0), 1)).tint(accent)
                            Text("\(b.pos) · \(pctText)").font(.system(size: 11)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                        } else {
                            Text(b.pos).font(.system(size: 11)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.18), lineWidth: 6)
                            Circle().trim(from: 0, to: min(1, CGFloat(minutes) / CGFloat(goal)))
                                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 0) {
                                Text("\(minutes)").font(.system(size: 16, weight: .bold))
                                Text("من \(goal)").font(.system(size: 9)).foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .frame(width: 58, height: 58)
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill").foregroundColor(.orange)
                            Text("\(streak)")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundColor(.white)
            } else {
                empty
            }
        }
        .widgetBackground(background)
    }

    private var circular: some View {
        Gauge(value: Double(min(minutes, goal)), in: 0...Double(goal)) {
            Image(systemName: "book")
        } currentValueLabel: {
            Text("\(minutes)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetBackground(Color.clear, pad: 0)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snap?.book?.title ?? "جليس").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let p = snap?.book?.pct { ProgressView(value: min(max(p, 0), 1)) }
            Text("\(pctText.isEmpty ? "" : pctText + " · ")\(minutes)/\(goal) د · 🔥\(streak)").font(.system(size: 11)).lineLimit(1)
        }
        .widgetBackground(Color.clear, pad: 0)
    }

    private var inline: some View {
        Label("\(minutes) من \(goal) د · \(streak) يوم", systemImage: "book")
            .widgetBackground(Color.clear, pad: 0)
    }
}

struct BookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WirdBook", provider: Provider()) { entry in
            BookWidgetView(entry: entry)
        }
        .configurationDisplayName("جليس")
        .description("كتابك الحالي وهدفك اليومي")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - session on the lock screen

struct SessionTimer: View {
    let state: WirdSessionAttributes.ContentState

    var body: some View {
        if let start = state.start, !state.paused {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        } else {
            Text(SessionTimer.format(state.elapsed)).monospacedDigit()
        }
    }

    static func format(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

struct SessionLockView: View {
    let context: ActivityViewContext<WirdSessionAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let dir = SharedGroup.container, let img = UIImage(contentsOfFile: dir.appendingPathComponent("cover.jpg").path) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(red: 0.17, green: 0.35, blue: 0.31)
                        Image(systemName: context.attributes.audio ? "headphones" : "book.fill").foregroundColor(.white)
                    }
                }
            }
            .frame(width: 40, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.audio ? "جلسة استماع" : "جلسة قراءة").font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                Text(context.attributes.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                if !context.state.pos.isEmpty {
                    Text(context.state.pos).font(.system(size: 11)).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                SessionTimer(state: context.state)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120, alignment: .trailing)
                if context.state.paused {
                    Text("متوقفة مؤقتًا").font(.system(size: 11)).foregroundColor(.orange)
                }
            }
        }
        .foregroundColor(.white)
        .padding(16)
        .environment(\.layoutDirection, Lang.direction)
    }
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WirdSessionAttributes.self) { context in
            SessionLockView(context: context)
                .activityBackgroundTint(Color(red: 0.04, green: 0.08, blue: 0.07).opacity(0.88))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "wird://session"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.audio ? "headphones" : "book.fill").foregroundColor(teal)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionTimer(state: context.state).font(.title3).frame(maxWidth: 90)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.title).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: context.attributes.audio ? "headphones" : "book.fill").foregroundColor(teal)
            } compactTrailing: {
                SessionTimer(state: context.state).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "book.fill").foregroundColor(teal)
            }
            .widgetURL(URL(string: "wird://session"))
        }
    }
}

// MARK: - a quote from the notebook, a different one each day

struct QuoteEntry: TimelineEntry {
    let date: Date
    let quote: WQuote?
    let accent: String?
}

struct QuoteProvider: TimelineProvider {
    static let sample = WQuote(t: "القراءة سفر لا يحتاج حقيبة.", b: "لكنود", a: "إسلام جمال", id: "")

    /// the same quote all day (even when you save new ones), the next one tomorrow
    static func pick(_ list: [WQuote], for date: Date) -> WQuote? {
        guard !list.isEmpty else { return nil }
        let key = WidgetData.dayKey(date)
        let file = SharedGroup.container?.appendingPathComponent("quote-day.json")
        if let f = file, let d = try? Data(contentsOf: f), let saved = try? JSONDecoder().decode([String: String].self, from: d),
           saved["day"] == key, let id = saved["id"], let q = list.first(where: { $0.id == id }) {
            return q
        }
        let day = Calendar.greg.ordinality(of: .day, in: .era, for: date) ?? 0
        let q = list[day % list.count]
        // only today's pick is remembered (the timeline also asks about midnight)
        if key == WidgetData.dayKey(Date()), let f = file, let d = try? JSONEncoder().encode(["day": key, "id": q.id]) {
            try? d.write(to: f, options: .atomic)
        }
        return q
    }

    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry(date: Date(), quote: QuoteProvider.sample, accent: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) {
        let (s, _) = WidgetData.load()
        let q = QuoteProvider.pick(s?.quotes ?? [], for: Date()) ?? (context.isPreview ? QuoteProvider.sample : nil)
        completion(QuoteEntry(date: Date(), quote: q, accent: s?.accent))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        let (s, _) = WidgetData.load()
        let now = Date()
        let midnight = Calendar.greg.startOfDay(for: now.addingTimeInterval(86_400))
        let list = s?.quotes ?? []
        let entries = [QuoteEntry(date: now, quote: QuoteProvider.pick(list, for: now), accent: s?.accent),
                       QuoteEntry(date: midnight, quote: QuoteProvider.pick(list, for: midnight), accent: s?.accent)]
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(120))))
    }
}

struct QuoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuoteEntry

    private var url: URL? {
        if let id = entry.quote?.id, !id.isEmpty { return URL(string: "wird://open?quote=\(id)") }
        return URL(string: "wird://open?tab=notebook")
    }

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.quote.map { "«\($0.t)»" } ?? "احفظ اقتباسًا في دفترك")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .lineLimit(3)
                    if let b = entry.quote?.b, !b.isEmpty { Text(b).font(.system(size: 11)).opacity(0.7).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetBackground(Color.clear, pad: 0)
            } else {
                let accent = Color(hex: entry.accent, fallback: teal)
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: family == .systemSmall ? 14 : 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                    if let q = entry.quote {
                        Text(q.t)
                            .font(.system(size: family == .systemSmall ? 15 : 18, weight: .medium, design: .serif))
                            .foregroundStyle(.white)
                            .lineLimit(family == .systemSmall ? 5 : 4)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        Text([q.b, q.a].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        Text("احفظ اقتباسًا في دفترك ويظهر هنا كل يوم")
                            .font(.system(size: 14, weight: .medium, design: .serif))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetBackground(LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing).overlay(Color.black.opacity(0.28)))
            }
        }
        .environment(\.layoutDirection, Lang.direction)
        .widgetURL(url)
    }
}

struct QuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JaleesQuote", provider: QuoteProvider()) { entry in
            QuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("اقتباس من دفترك")
        .description("اقتباس من اللي حفظته، يتغير كل يوم")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

// MARK: - new chapters of your novels

struct NovelsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WirdEntry
    private var accent: Color { Color(hex: entry.snap?.accent, fallback: teal) }
    private var list: [WNovel] { entry.snap?.novels ?? [] }

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    if let n = list.first {
                        Text(n.t).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(n.fresh > 0 ? "\(n.fresh) جديد · الفصل \(n.last)" : "\(n.unread) غير مقروء").font(.system(size: 11)).lineLimit(1)
                    } else {
                        Text("ما فيه فصول تنتظرك").font(.system(size: 12))
                    }
                }
                .widgetBackground(Color.clear, pad: 0)
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 7) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").foregroundColor(accent)
                        Text("الجديد في رواياتك").font(.system(size: 12, weight: .bold))
                    }
                    if list.isEmpty {
                        Spacer(minLength: 0)
                        Text("ما فيه فصول تنتظرك. لما تنزل فصول جديدة تطلع هنا.").font(.system(size: 12)).foregroundColor(.white.opacity(0.75))
                        Spacer(minLength: 0)
                    } else {
                        ForEach(Array(list.prefix(family == .systemSmall ? 2 : 3).enumerated()), id: \.offset) { _, n in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.t).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                HStack(spacing: 5) {
                                    if n.fresh > 0 {
                                        Text("\(n.fresh) جديد").font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(accent))
                                    }
                                    Text("\(n.unread) غير مقروء · آخرها \(n.last)").font(.system(size: 10.5)).foregroundColor(.white.opacity(0.75)).lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetBackground(LinearGradient(colors: [accent.opacity(0.55), Color(red: 0.04, green: 0.07, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .environment(\.layoutDirection, Lang.direction)
        .widgetURL(URL(string: "wird://open?tab=updates"))
    }
}

struct NovelsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JaleesNovels", provider: Provider()) { entry in
            NovelsWidgetView(entry: entry)
        }
        .configurationDisplayName("الجديد في رواياتك")
        .description("الروايات اللي نزلت لها فصول ولسا ما قريتها")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct WirdWidgets: WidgetBundle {
    var body: some Widget {
        BookWidget()
        NovelsWidget()
        QuoteWidget()
        SessionLiveActivity()
    }
}
